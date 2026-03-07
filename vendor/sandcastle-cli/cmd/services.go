package cmd

import (
	"fmt"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

var serviceSave bool

func init() {
	rootCmd.AddCommand(dockerCmd)
	rootCmd.AddCommand(vncCmd)

	for _, cmd := range []*cobra.Command{dockerStartCmd, dockerStopCmd, vncStartCmd, vncStopCmd} {
		cmd.Flags().BoolVar(&serviceSave, "save", false, "Persist this setting so the service stays on/off after container restart")
	}

	dockerCmd.AddCommand(dockerStartCmd)
	dockerCmd.AddCommand(dockerStopCmd)
	vncCmd.AddCommand(vncStartCmd)
	vncCmd.AddCommand(vncStopCmd)
}

var dockerCmd = &cobra.Command{
	Use:   "docker",
	Short: "Manage Docker daemon inside a sandbox",
}

var vncCmd = &cobra.Command{
	Use:   "vnc",
	Short: "Manage VNC display server inside a sandbox",
}

var dockerStartCmd = &cobra.Command{
	Use:   "start <sandbox>",
	Short: "Start Docker daemon inside a sandbox",
	Args:  cobra.ExactArgs(1),
	RunE:  serviceRunE("docker", "start"),
}

var dockerStopCmd = &cobra.Command{
	Use:   "stop <sandbox>",
	Short: "Stop Docker daemon inside a sandbox",
	Args:  cobra.ExactArgs(1),
	RunE:  serviceRunE("docker", "stop"),
}

var vncStartCmd = &cobra.Command{
	Use:   "start <sandbox>",
	Short: "Start VNC display server inside a sandbox",
	Args:  cobra.ExactArgs(1),
	RunE:  serviceRunE("vnc", "start"),
}

var vncStopCmd = &cobra.Command{
	Use:   "stop <sandbox>",
	Short: "Stop VNC display server inside a sandbox",
	Args:  cobra.ExactArgs(1),
	RunE:  serviceRunE("vnc", "stop"),
}

func serviceRunE(service, action string) func(cmd *cobra.Command, args []string) error {
	return func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		var result *api.Sandbox
		switch action {
		case "start":
			result, err = client.ServiceStart(sandbox.ID, service, serviceSave)
		case "stop":
			result, err = client.ServiceStop(sandbox.ID, service, serviceSave)
		}
		if err != nil {
			return err
		}

		label := service
		if service == "docker" {
			label = "Docker daemon"
		} else if service == "vnc" {
			label = "VNC display"
		}

		verb := "started"
		if action == "stop" {
			verb = "stopped"
		}

		fmt.Printf("%s %s in sandbox %q.", label, verb, result.Name)
		if serviceSave {
			fmt.Print(" (saved for restart)")
		}
		fmt.Println()
		return nil
	}
}
