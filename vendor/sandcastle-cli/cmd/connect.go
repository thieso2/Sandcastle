package cmd

import (
	"fmt"
	"net"
	"os"
	"os/exec"
	"strconv"
	"time"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(connectCmd)
	rootCmd.AddCommand(sshCmd)
}

var connectCmd = &cobra.Command{
	Use:   "connect [name]",
	Short: "SSH into sandbox and attach tmux (auto-starts if stopped)",
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

		// SSH with tmux attach-or-create
		return sshExec(info.Host, info.Port, info.User, "tmux new-session -A -s main")
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

		return sshExec(info.Host, info.Port, info.User, "")
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

	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", addr, time.Second)
		if err == nil {
			conn.Close()
			if printed {
				fmt.Println()
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

func sshExec(host string, port int, user string, remoteCmd string) error {
	sshArgs := []string{
		"-p", strconv.Itoa(port),
		"-o", "StrictHostKeyChecking=no",
		"-o", "UserKnownHostsFile=/dev/null",
		"-o", "LogLevel=ERROR",
		fmt.Sprintf("%s@%s", user, host),
	}
	if remoteCmd != "" {
		sshArgs = append(sshArgs, "-t", remoteCmd)
	}

	sshPath, err := exec.LookPath("ssh")
	if err != nil {
		return fmt.Errorf("ssh not found: %w", err)
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
