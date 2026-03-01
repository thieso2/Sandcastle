package cmd

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

var connectMosh bool

func init() {
	rootCmd.AddCommand(connectCmd)
	rootCmd.AddCommand(sshCmd)
	connectCmd.Flags().BoolVar(&connectMosh, "mosh", false, "Connect using mosh instead of SSH (requires mosh on client)")
}

var connectCmd = &cobra.Command{
	Use:   "connect [name]",
	Short: "Connect to sandbox and attach tmux (auto-starts if stopped)",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name := resolveSandboxName(args)
		if name == "" {
			return fmt.Errorf("specify a sandbox name or set one with: sandcastle use <name>")
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, name)
		if err != nil {
			return err
		}

		// Auto-start if stopped
		if sandbox.Status == "stopped" {
			fmt.Printf("Starting sandbox %q...\n", name)
			sandbox, err = client.StartSandbox(sandbox.ID)
			if err != nil {
				return fmt.Errorf("failed to start sandbox: %w", err)
			}
		}

		info, err := client.ConnectInfo(sandbox.ID)
		if err != nil {
			return err
		}

		if err := waitForSSH(info.Host, info.Port); err != nil {
			return err
		}

		cfg, err := config.Load()
		if err != nil {
			return err
		}
		prefs := cfg.LoadPreferences()

		var remoteCmd string
		if *prefs.UseTmux {
			remoteCmd = "tmux new-session -A -s main"
		}

		// --mosh flag takes precedence over ConnectProtocol preference
		if connectMosh || prefs.ConnectProtocol == "mosh" {
			return moshExec(info.Host, info.Port, info.User, remoteCmd, prefs.SSHExtraArgs)
		}
		return sshExec(info.Host, info.Port, info.User, remoteCmd, prefs.SSHExtraArgs)
	},
}

var sshCmd = &cobra.Command{
	Use:   "ssh [name]",
	Short: "SSH into sandbox shell (without tmux)",
	Args:  cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name := resolveSandboxName(args)
		if name == "" {
			return fmt.Errorf("specify a sandbox name or set one with: sandcastle use <name>")
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, name)
		if err != nil {
			return err
		}

		info, err := client.ConnectInfo(sandbox.ID)
		if err != nil {
			return err
		}

		if err := waitForSSH(info.Host, info.Port); err != nil {
			return err
		}

		cfg, err := config.Load()
		if err != nil {
			return err
		}
		prefs := cfg.LoadPreferences()

		return sshExec(info.Host, info.Port, info.User, "", prefs.SSHExtraArgs)
	},
}

func resolveSandboxName(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	return ""
}

func waitForSSH(host string, port int) error {
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	deadline := time.Now().Add(30 * time.Second)
	printed := false

	if os.Getenv("VERBOSE") == "1" {
		fmt.Fprintf(os.Stderr, "\033[2m[verbose] Waiting for SSH at %s (timeout: 30s)\033[0m\n", addr)
	}

	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			conn.Close()
			if printed {
				fmt.Println()
			}
			if os.Getenv("VERBOSE") == "1" {
				fmt.Fprintf(os.Stderr, "\033[2m[verbose] SSH connection successful!\033[0m\n")
			}
			return nil
		}
		if !printed {
			fmt.Printf("Waiting for SSH to be ready...")
			printed = true
		}
		fmt.Print(".")
		time.Sleep(500 * time.Millisecond)
	}

	fmt.Println()
	return fmt.Errorf("timeout waiting for SSH at %s", addr)
}

func sshExec(host string, port int, user string, remoteCmd string, extraArgs string) error {
	sshArgs := []string{
		"-p", strconv.Itoa(port),
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
	}
	if extraArgs != "" {
		sshArgs = append(sshArgs, strings.Fields(extraArgs)...)
	}
	sshArgs = append(sshArgs, fmt.Sprintf("%s@%s", user, host))
	if remoteCmd != "" {
		sshArgs = append(sshArgs, "-t", remoteCmd)
	}

	sshPath, err := exec.LookPath("ssh")
	if err != nil {
		return fmt.Errorf("ssh not found: %w", err)
	}

	if os.Getenv("VERBOSE") == "1" {
		fmt.Fprintf(os.Stderr, "→ ssh %s\n", shellJoin(sshArgs))
	}

	proc := &os.ProcAttr{
		Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
	}
	process, err := os.StartProcess(sshPath, append([]string{"ssh"}, sshArgs...), proc)
	if err != nil {
		return fmt.Errorf("starting ssh: %w", err)
	}

	state, err := process.Wait()
	if err != nil {
		return err
	}
	if !state.Success() {
		os.Exit(state.ExitCode())
	}
	return nil
}

func moshExec(host string, port int, user string, remoteCmd string, extraArgs string) error {
	sshOpts := fmt.Sprintf("ssh -p %d -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR", port)
	if extraArgs != "" {
		sshOpts += " " + extraArgs
	}

	moshArgs := []string{
		"--ssh=" + sshOpts,
		fmt.Sprintf("%s@%s", user, host),
	}
	if remoteCmd != "" {
		moshArgs = append(moshArgs, "--")
		moshArgs = append(moshArgs, strings.Fields(remoteCmd)...)
	}

	moshPath, err := exec.LookPath("mosh")
	if err != nil {
		return fmt.Errorf("mosh not found in PATH — install mosh on your local machine first (https://mosh.org): %w", err)
	}

	if os.Getenv("VERBOSE") == "1" {
		fmt.Fprintf(os.Stderr, "→ mosh %s\n", shellJoin(moshArgs))
	}

	proc := &os.ProcAttr{
		Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
	}
	process, err := os.StartProcess(moshPath, append([]string{"mosh"}, moshArgs...), proc)
	if err != nil {
		return fmt.Errorf("starting mosh: %w", err)
	}

	state, err := process.Wait()
	if err != nil {
		return err
	}
	if !state.Success() {
		os.Exit(state.ExitCode())
	}
	return nil
}

func shellJoin(args []string) string {
	quoted := make([]string, len(args))
	for i, a := range args {
		if strings.ContainsAny(a, " \t\n\"'\\") {
			quoted[i] = fmt.Sprintf("%q", a)
		} else {
			quoted[i] = a
		}
	}
	return strings.Join(quoted, " ")
}
