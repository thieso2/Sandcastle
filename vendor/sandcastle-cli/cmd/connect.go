package cmd

import (
	"context"
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

const tmuxCmd = "if command -v ssh-agent-switcher >/dev/null 2>&1; then ssh-agent-switcher --daemon 2>/dev/null; export SSH_AUTH_SOCK=/tmp/ssh-agent.$USER; fi; tmux new-session -A -s main"

var connectMosh bool
var connectSSH bool

func init() {
	rootCmd.AddCommand(connectCmd)
	rootCmd.AddCommand(sshCmd)
	connectCmd.Flags().BoolVar(&connectMosh, "mosh", false, "Connect using mosh (overrides config preference)")
	connectCmd.Flags().BoolVar(&connectSSH, "ssh", false, "Connect using SSH (overrides config preference)")
}

var connectCmd = &cobra.Command{
	Use:     "connect [name] [-- ssh-options...]",
	Aliases: []string{"c"},
	Short:   "Connect to sandbox and attach tmux (auto-starts if stopped)",
	Args:  cobra.ArbitraryArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		name, passthrough := splitArgs(args)
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
			remoteCmd = tmuxCmd
		}

		// Explicit flags take precedence; otherwise auto-detect or use saved preference
		var protocol string
		switch {
		case connectMosh:
			protocol = "mosh"
		case connectSSH:
			protocol = "ssh"
		default:
			protocol = pickProtocol(cfg, info.Host, info.Port, info.User, prefs.SSHExtraArgs)
		}

		if protocol == "mosh" {
			return moshExec(info.Host, info.Port, info.User, remoteCmd, prefs.SSHExtraArgs, passthrough)
		}
		return sshExec(info.Host, info.Port, info.User, remoteCmd, prefs.SSHExtraArgs, passthrough)
	},
}

var sshCmd = &cobra.Command{
	Use:     "ssh [name] [-- ssh-options...]",
	Aliases: []string{"s"},
	Short:   "SSH into sandbox shell (without tmux)",
	Args:  cobra.ArbitraryArgs,
	RunE: func(cmd *cobra.Command, args []string) error {
		name, passthrough := splitArgs(args)
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

		return sshExec(info.Host, info.Port, info.User, "", prefs.SSHExtraArgs, passthrough)
	},
}

func resolveSandboxName(args []string) string {
	if len(args) > 0 {
		return args[0]
	}
	return ""
}

func splitArgs(args []string) (string, []string) {
	if len(args) == 0 {
		return "", nil
	}
	return args[0], args[1:]
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

func sshExec(host string, port int, user string, remoteCmd string, extraArgs string, passthrough []string) error {
	sshArgs := []string{
		"-A",
		"-p", strconv.Itoa(port),
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
	}
	if extraArgs != "" {
		sshArgs = append(sshArgs, strings.Fields(extraArgs)...)
	}
	sshArgs = append(sshArgs, passthrough...)
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

func moshExec(host string, port int, user string, remoteCmd string, extraArgs string, passthrough []string) error {
	sshOpts := fmt.Sprintf("ssh -A -p %d -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR", port)
	if extraArgs != "" {
		sshOpts += " " + extraArgs
	}
	if len(passthrough) > 0 {
		sshOpts += " " + strings.Join(passthrough, " ")
	}

	moshArgs := []string{
		"--ssh=" + sshOpts,
		fmt.Sprintf("%s@%s", user, host),
	}
	if remoteCmd != "" {
		moshArgs = append(moshArgs, "--", "bash", "-c", remoteCmd)
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

// moshAvailableLocally reports whether mosh is installed on this machine.
func moshAvailableLocally() bool {
	_, err := exec.LookPath("mosh")
	return err == nil
}

// moshAvailableRemotely probes the remote host by running `which mosh` over SSH.
func moshAvailableRemotely(host string, port int, user, extraArgs string) bool {
	sshArgs := []string{
		"-p", strconv.Itoa(port),
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
		"-o", "ConnectTimeout=5",
	}
	if extraArgs != "" {
		sshArgs = append(sshArgs, strings.Fields(extraArgs)...)
	}
	sshArgs = append(sshArgs, fmt.Sprintf("%s@%s", user, host), "which mosh")

	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, "ssh", sshArgs...).Run() == nil
}

// pickProtocol returns "mosh" or "ssh". When no protocol is explicitly configured
// it auto-detects mosh availability on both sides, saves "mosh" to config if found,
// and falls back to "ssh" otherwise.
func pickProtocol(cfg *config.Config, host string, port int, user, extraArgs string) string {
	// Explicit env var or saved config preference → honour it.
	if os.Getenv("SANDCASTLE_CONNECT_PROTOCOL") != "" || cfg.Preferences.ConnectProtocol != "" {
		return cfg.LoadPreferences().ConnectProtocol
	}

	// Auto-detect: need mosh on both sides.
	if !moshAvailableLocally() {
		return "ssh"
	}
	fmt.Print("Checking for mosh on remote...")
	if !moshAvailableRemotely(host, port, user, extraArgs) {
		fmt.Println(" not found, using SSH")
		return "ssh"
	}
	fmt.Println(" found! Using mosh (saved to config)")
	cfg.Preferences.ConnectProtocol = "mosh"
	_ = config.Save(cfg)
	return "mosh"
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
