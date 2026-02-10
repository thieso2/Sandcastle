package cmd

import (
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"time"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(loginCmd)
}

var loginCmd = &cobra.Command{
	Use:   "login <url> [alias]",
	Short: "Authenticate with a Sandcastle server via browser",
	Long: `Authenticate with a Sandcastle server using the device authorization flow.
Opens a browser window where you approve the CLI, then saves the token.

Examples:
  sandcastle login https://demo.sandcastle.rocks
  sandcastle login https://demo.sandcastle.rocks prod
  sandcastle login http://localhost:3000 local`,
	Args: cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		serverURL := strings.TrimRight(args[0], "/")

		// Derive alias from URL if not provided
		alias := ""
		if len(args) > 1 {
			alias = args[1]
		} else {
			alias = deriveAlias(serverURL)
		}

		// Get device code from server
		hostname, _ := os.Hostname()
		client := api.NewClientWithToken(serverURL, "")
		deviceCode, err := client.RequestDeviceCode(fmt.Sprintf("cli-%s", hostname))
		if err != nil {
			return fmt.Errorf("requesting device code: %w", err)
		}

		fmt.Printf("Your code: %s\n\n", deviceCode.UserCode)
		fmt.Printf("Open this URL to authorize:\n  %s\n\n", deviceCode.VerificationURL)

		// Try to open browser
		if err := openBrowser(deviceCode.VerificationURL); err == nil {
			fmt.Println("Browser opened. Waiting for authorization...")
		} else {
			fmt.Println("Waiting for authorization...")
		}

		// Poll for token
		interval := time.Duration(deviceCode.Interval) * time.Second
		if interval < time.Second {
			interval = 3 * time.Second
		}

		deadline := time.Now().Add(time.Duration(deviceCode.ExpiresIn) * time.Second)
		for time.Now().Before(deadline) {
			time.Sleep(interval)

			token, pending, err := client.PollDeviceToken(deviceCode.DeviceCode)
			if err != nil {
				return fmt.Errorf("authorization failed: %w", err)
			}
			if pending {
				continue
			}

			// Save to config
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("loading config: %w", err)
			}

			cfg.SetServer(alias, serverURL, token)
			if err := config.Save(cfg); err != nil {
				return fmt.Errorf("saving config: %w", err)
			}

			fmt.Printf("\nLogged in to %s (alias: %s)\n", serverURL, alias)
			return nil
		}

		return fmt.Errorf("authorization timed out — please try again")
	},
}

func deriveAlias(serverURL string) string {
	u, err := url.Parse(serverURL)
	if err != nil {
		return "default"
	}
	host := u.Hostname()

	// Use first subdomain or "local" for localhost
	if host == "localhost" || host == "127.0.0.1" {
		return "local"
	}

	parts := strings.Split(host, ".")
	if len(parts) > 0 {
		return parts[0]
	}
	return "default"
}

func openBrowser(url string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", url).Start()
	case "linux":
		return exec.Command("xdg-open", url).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	default:
		return fmt.Errorf("unsupported platform")
	}
}
