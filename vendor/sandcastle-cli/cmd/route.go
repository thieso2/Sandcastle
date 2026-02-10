package cmd

import (
	"fmt"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

var (
	routePort   int
	routeRemove bool
)

func init() {
	rootCmd.AddCommand(routeCmd)
	routeCmd.Flags().IntVar(&routePort, "port", 8080, "Container port to route to")
	routeCmd.Flags().BoolVar(&routeRemove, "remove", false, "Remove existing route")
}

var routeCmd = &cobra.Command{
	Use:   "route <sandbox> [domain]",
	Short: "Manage custom domain routing for a sandbox",
	Long: `Add, show, or remove a custom domain route for a sandbox.

Examples:
  sandcastle route myapp app.example.com              # Add route (default port 8080)
  sandcastle route myapp app.example.com --port 3000  # Custom port
  sandcastle route myapp                              # Show current route
  sandcastle route myapp --remove                     # Remove route`,
	Args: cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		// Remove route
		if routeRemove {
			if err := client.RemoveRoute(sandbox.ID); err != nil {
				return err
			}
			fmt.Printf("Route removed from sandbox %q.\n", sandbox.Name)
			return nil
		}

		// Show route (no domain arg)
		if len(args) == 1 {
			route, err := client.GetRoute(sandbox.ID)
			if err != nil {
				return err
			}
			fmt.Printf("Domain:  %s\n", route.Domain)
			fmt.Printf("Port:    %d\n", route.Port)
			fmt.Printf("URL:     %s\n", route.URL)
			return nil
		}

		// Add route
		route, err := client.AddRoute(sandbox.ID, api.RouteRequest{
			Domain: args[1],
			Port:   routePort,
		})
		if err != nil {
			return err
		}

		fmt.Printf("Route added to sandbox %q.\n", sandbox.Name)
		fmt.Printf("  Domain: %s\n", route.Domain)
		fmt.Printf("  Port:   %d\n", route.Port)
		fmt.Printf("  URL:    %s\n", route.URL)
		fmt.Println("\nPoint your DNS to this server, and Traefik will handle TLS automatically.")
		return nil
	},
}
