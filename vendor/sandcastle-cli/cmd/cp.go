package cmd

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

var cpRecursive bool

func init() {
	rootCmd.AddCommand(cpCmd)
	cpCmd.Flags().BoolVarP(&cpRecursive, "recursive", "r", false, "Copy directories recursively")
}

var cpCmd = &cobra.Command{
	Use:   "cp <src> <dst>",
	Short: "Copy files to/from a sandbox via scp",
	Long: `Copy files between local machine and a sandbox using scp.

Use sandbox:path syntax to reference files in a sandbox:
  sandcastle cp file.txt my-dev:~/          # local → sandbox
  sandcastle cp my-dev:~/data.csv .         # sandbox → local
  sandcastle cp -r my-dev:~/project ./      # recursive copy from sandbox
  sandcastle cp -r ./dist my-dev:~/app/     # recursive copy to sandbox`,
	Args: cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		src := args[0]
		dst := args[1]

		srcSandbox, srcPath := parseCpArg(src)
		dstSandbox, dstPath := parseCpArg(dst)

		if srcSandbox != "" && dstSandbox != "" {
			return fmt.Errorf("cannot copy between two sandboxes directly — copy to local first")
		}
		if srcSandbox == "" && dstSandbox == "" {
			return fmt.Errorf("one of src or dst must be a sandbox (use sandbox:path syntax)")
		}

		sandboxName := srcSandbox
		if sandboxName == "" {
			sandboxName = dstSandbox
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, sandboxName)
		if err != nil {
			return err
		}

		info, err := client.ConnectInfo(sandbox.ID)
		if err != nil {
			return err
		}

		cfg, err := config.Load()
		if err != nil {
			return err
		}
		prefs := cfg.LoadPreferences()

		scpArgs := []string{
			"-P", strconv.Itoa(info.Port),
			"-o", "StrictHostKeyChecking=no",
			"-o", "UserKnownHostsFile=/dev/null",
			"-o", "LogLevel=ERROR",
		}
		if prefs.SSHExtraArgs != "" {
			scpArgs = append(scpArgs, strings.Fields(prefs.SSHExtraArgs)...)
		}
		if cpRecursive {
			scpArgs = append(scpArgs, "-r")
		}

		// Build scp src/dst with user@host: prefix for sandbox side
		remote := fmt.Sprintf("%s@%s", info.User, info.Host)
		if srcSandbox != "" {
			scpArgs = append(scpArgs, remote+":"+srcPath, dstPath)
		} else {
			scpArgs = append(scpArgs, srcPath, remote+":"+dstPath)
		}

		if os.Getenv("VERBOSE") == "1" {
			fmt.Fprintf(os.Stderr, "→ scp %s\n", shellJoin(scpArgs))
		}

		scpPath, err := exec.LookPath("scp")
		if err != nil {
			return fmt.Errorf("scp not found: %w", err)
		}

		proc := &os.ProcAttr{
			Files: []*os.File{os.Stdin, os.Stdout, os.Stderr},
		}
		process, err := os.StartProcess(scpPath, append([]string{"scp"}, scpArgs...), proc)
		if err != nil {
			return fmt.Errorf("starting scp: %w", err)
		}

		state, err := process.Wait()
		if err != nil {
			return err
		}
		if !state.Success() {
			os.Exit(state.ExitCode())
		}
		return nil
	},
}

// parseCpArg splits "sandbox:path" into (sandbox, path).
// If no colon, returns ("", arg) — it's a local path.
func parseCpArg(arg string) (string, string) {
	// Don't split on Windows-style paths like C:\...
	// A sandbox name is always lowercase alpha + digits + hyphens
	idx := strings.Index(arg, ":")
	if idx <= 0 {
		return "", arg
	}
	name := arg[:idx]
	// Validate it looks like a sandbox name (not a drive letter or absolute path)
	for _, c := range name {
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
			return "", arg
		}
	}
	return name, arg[idx+1:]
}
