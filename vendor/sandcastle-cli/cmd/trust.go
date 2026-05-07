package cmd

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

const trustCertFile = "sandcastle-caddy-rootCA.pem"

func init() {
	rootCmd.AddCommand(trustCmd)
	trustCmd.AddCommand(trustInstallCmd)
	trustCmd.AddCommand(trustStatusCmd)
	trustCmd.AddCommand(trustUninstallCmd)
}

var trustCmd = &cobra.Command{
	Use:   "trust",
	Short: "Install the Sandcastle HTTPS root CA on this client",
}

var trustInstallCmd = &cobra.Command{
	Use:   "install",
	Short: "Trust Sandcastle sandbox HTTPS certificates on this client",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		ca, err := client.TrustRootCA()
		if err != nil {
			return err
		}
		path, err := writeTrustRoot(client, ca.PEM)
		if err != nil {
			return err
		}
		if err := installTrustRoot(path); err != nil {
			return err
		}

		fmt.Printf("Installed %s for Sandcastle sandbox HTTPS.\n", ca.Name)
		fmt.Printf("Local copy: %s\n", path)
		return nil
	},
}

var trustStatusCmd = &cobra.Command{
	Use:   "status",
	Short: "Show whether the Sandcastle HTTPS root CA is installed",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		ca, err := client.TrustRootCA()
		if err != nil {
			return err
		}
		path, installed, err := trustRootStatus(client, ca.PEM)
		if err != nil {
			return err
		}

		fmt.Printf("Root CA fingerprint: %s\n", fingerprint(ca.PEM))
		fmt.Printf("Local copy: %s\n", path)
		if installed {
			fmt.Println("Status: installed")
		} else {
			fmt.Println("Status: not installed")
			fmt.Println("Run: sandcastle trust install")
		}
		return nil
	},
}

var trustUninstallCmd = &cobra.Command{
	Use:   "uninstall",
	Short: "Remove the Sandcastle HTTPS root CA from this client",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		path := trustRootPath(client)
		if err := uninstallTrustRoot(path); err != nil {
			return err
		}
		_ = os.Remove(path)
		fmt.Println("Removed Sandcastle sandbox HTTPS trust from this client.")
		return nil
	},
}

func writeTrustRoot(client *api.Client, pem string) (string, error) {
	path := trustRootPath(client)
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return "", fmt.Errorf("creating cert directory: %w", err)
	}
	if err := os.WriteFile(path, []byte(pem), 0o644); err != nil {
		return "", fmt.Errorf("writing root CA: %w", err)
	}
	return path, nil
}

func trustRootStatus(client *api.Client, pem string) (string, bool, error) {
	path := trustRootPath(client)
	local, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return path, false, fmt.Errorf("reading local root CA: %w", err)
	}
	if !bytes.Equal(bytes.TrimSpace(local), bytes.TrimSpace([]byte(pem))) {
		return path, false, nil
	}

	installed, err := osTrustInstalled(path)
	return path, installed, err
}

func trustRootPath(client *api.Client) string {
	name := client.ServerAlias
	if name == "" {
		name = strings.TrimPrefix(strings.TrimPrefix(client.BaseURL, "https://"), "http://")
	}
	name = strings.NewReplacer("/", "-", ":", "-", ".", "-").Replace(strings.Trim(name, "-"))
	if name == "" {
		name = "default"
	}
	return filepath.Join(config.Dir(), "certs", name, trustCertFile)
}

func installTrustRoot(path string) error {
	switch runtime.GOOS {
	case "darwin":
		return run("sudo", "security", "add-trusted-cert", "-d", "-r", "trustRoot", "-k", "/Library/Keychains/System.keychain", path)
	case "linux":
		if _, err := os.Stat("/usr/local/share/ca-certificates"); err == nil {
			target := "/usr/local/share/ca-certificates/sandcastle-caddy-rootCA.crt"
			if err := run("sudo", "cp", path, target); err != nil {
				return err
			}
			return run("sudo", "update-ca-certificates")
		}
		if _, err := os.Stat("/etc/pki/ca-trust/source/anchors"); err == nil {
			target := "/etc/pki/ca-trust/source/anchors/sandcastle-caddy-rootCA.crt"
			if err := run("sudo", "cp", path, target); err != nil {
				return err
			}
			return run("sudo", "update-ca-trust")
		}
		return fmt.Errorf("unsupported Linux trust store; install %s manually", path)
	default:
		return fmt.Errorf("unsupported OS %q; install %s manually", runtime.GOOS, path)
	}
}

func uninstallTrustRoot(path string) error {
	switch runtime.GOOS {
	case "darwin":
		if _, err := os.Stat(path); os.IsNotExist(err) {
			return nil
		}
		return run("sudo", "security", "delete-certificate", "-c", "Sandcastle Caddy Root CA", "/Library/Keychains/System.keychain")
	case "linux":
		debianTarget := "/usr/local/share/ca-certificates/sandcastle-caddy-rootCA.crt"
		if _, err := os.Stat(debianTarget); err == nil {
			if err := run("sudo", "rm", "-f", debianTarget); err != nil {
				return err
			}
			return run("sudo", "update-ca-certificates")
		}
		fedoraTarget := "/etc/pki/ca-trust/source/anchors/sandcastle-caddy-rootCA.crt"
		if _, err := os.Stat(fedoraTarget); err == nil {
			if err := run("sudo", "rm", "-f", fedoraTarget); err != nil {
				return err
			}
			return run("sudo", "update-ca-trust")
		}
		return nil
	default:
		return fmt.Errorf("unsupported OS %q; remove %s manually", runtime.GOOS, path)
	}
}

func osTrustInstalled(path string) (bool, error) {
	switch runtime.GOOS {
	case "darwin":
		local, err := os.ReadFile(path)
		if err != nil {
			return false, err
		}
		output, err := exec.Command("security", "find-certificate", "-c", "Sandcastle Caddy Root CA", "-a", "-p", "/Library/Keychains/System.keychain").Output()
		if err != nil {
			return false, nil
		}
		return bytes.Contains(bytes.TrimSpace(output), bytes.TrimSpace(local)), nil
	case "linux":
		targets := []string{
			"/usr/local/share/ca-certificates/sandcastle-caddy-rootCA.crt",
			"/etc/pki/ca-trust/source/anchors/sandcastle-caddy-rootCA.crt",
		}
		local, err := os.ReadFile(path)
		if err != nil {
			return false, err
		}
		for _, target := range targets {
			content, err := os.ReadFile(target)
			if err == nil && bytes.Equal(bytes.TrimSpace(local), bytes.TrimSpace(content)) {
				return true, nil
			}
		}
		return false, nil
	default:
		return false, nil
	}
}

func fingerprint(pem string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(pem)))
	encoded := strings.ToUpper(hex.EncodeToString(sum[:]))
	chunks := make([]string, 0, len(encoded)/2)
	for i := 0; i < len(encoded); i += 2 {
		chunks = append(chunks, encoded[i:i+2])
	}
	return strings.Join(chunks, ":")
}
