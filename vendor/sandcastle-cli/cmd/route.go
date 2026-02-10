package cmd

import (
	"fmt"
	"strconv"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(routeCmd)
	routeCmd.AddCommand(routeSetCmd)
	routeCmd.AddCommand(routeDeleteCmd)
}

var routeCmd = &cobra.Command{
	Use:   "route",
	Short: "Manage custom domain routing for a sandbox",
	Long: `Add, show, or remove a custom domain route for a sandbox.

Examples:
  sandcastle route set myapp app.example.com         # Add route (default port 8080)
  sandcastle route set myapp app.example.com 3000    # Custom port
  sandcastle route delete myapp                      # Remove route`,
}

var routeSetCmd = &cobra.Command{
	Use:   "set <sandbox> <domain> [port]",
	Short: "Set a custom domain route (overwrites existing)",
	Args:  cobra.RangeArgs(2, 3),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		port := 8080
		if len(args) == 3 {
			port, err = strconv.Atoi(args[2])
			if err != nil {
				return fmt.Errorf("invalid port: %s", args[2])
			}
		}

		route, err := client.AddRoute(sandbox.ID, api.RouteRequest{
			Domain: args[1],
			Port:   port,
		})
		if err != nil {
			return err
		}

		fmt.Printf("Route set for sandbox %q.\n", sandbox.Name)
		fmt.Printf("  Domain: %s\n", route.Domain)
		fmt.Printf("  Port:   %d\n", route.Port)
		fmt.Printf("  URL:    %s\n", route.URL)
		fmt.Println("\nPoint your DNS to this server, and Traefik will handle TLS automatically.")
		return nil
	},
}

var routeDeleteCmd = &cobra.Command{
	Use:   "delete <sandbox>",
	Short: "Remove a custom domain route",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		if err := client.RemoveRoute(sandbox.ID); err != nil {
			return err
		}

		fmt.Printf("Route removed from sandbox %q.\n", sandbox.Name)
		return nil
	},
}
