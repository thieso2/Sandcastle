package cmd

import (
	"fmt"
	"strings"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(execCmd)
}

var execCmd = &cobra.Command{
	Use:   "exec <name> -- <command...>",
	Short: "Run a single command in a sandbox",
	Args:  cobra.MinimumNArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		name := args[0]
		remoteCmd := strings.Join(args[1:], " ")

		// If first arg looks like it could be a command (no sandbox found), try active sandbox
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, name)
		if err != nil {
			// Maybe the name is actually part of the command, use active sandbox
			active := config.ActiveSandbox()
			if active == "" {
				return fmt.Errorf("sandbox %q not found and no active sandbox set", name)
			}
			sandbox, err = findSandboxByName(client, active)
			if err != nil {
				return err
			}
			remoteCmd = strings.Join(args, " ")
		}

		info, err := client.ConnectInfo(sandbox.ID)
		if err != nil {
			return err
		}

		return sshExec(info.Host, info.Port, info.User, remoteCmd)
	},
}
