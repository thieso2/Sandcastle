package cmd

import (
	"fmt"
	"os"
	"strconv"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(routeCmd)
	routeCmd.AddCommand(routeAddCmd)
	routeCmd.AddCommand(routeListCmd)
	routeCmd.AddCommand(routeDeleteCmd)
}

var routeCmd = &cobra.Command{
	Use:   "route",
	Short: "Manage custom domain routes for a sandbox",
	Long: `Add, list, or remove custom domain routes for a sandbox.
Each sandbox can have multiple routes pointing to different ports.

Examples:
  sandcastle route add myapp app.example.com         # Add route (default port 8080)
  sandcastle route add myapp api.example.com 3000    # Add route on custom port
  sandcastle route list myapp                        # List all routes
  sandcastle route delete myapp app.example.com      # Remove a specific route`,
}

var routeAddCmd = &cobra.Command{
	Use:   "add <sandbox> <domain> [port]",
	Short: "Add a custom domain route",
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

		fmt.Printf("Route added for sandbox %q.\n", sandbox.Name)
		fmt.Printf("  Domain: %s\n", route.Domain)
		fmt.Printf("  Port:   %d\n", route.Port)
		fmt.Printf("  URL:    %s\n", route.URL)
		fmt.Println("\nPoint your DNS to this server, and Traefik will handle TLS automatically.")
		return nil
	},
}

var routeListCmd = &cobra.Command{
	Use:   "list <sandbox>",
	Short: "List all routes for a sandbox",
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

		routes, err := client.ListRoutes(sandbox.ID)
		if err != nil {
			return err
		}

		if len(routes) == 0 {
			fmt.Printf("No routes for sandbox %q.\n", sandbox.Name)
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "DOMAIN\tPORT\tURL")
		for _, r := range routes {
			fmt.Fprintf(w, "%s\t%d\t%s\n", r.Domain, r.Port, r.URL)
		}
		w.Flush()
		return nil
	},
}

var routeDeleteCmd = &cobra.Command{
	Use:   "delete <sandbox> <domain>",
	Short: "Remove a custom domain route",
	Args:  cobra.ExactArgs(2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		if err := client.RemoveRoute(sandbox.ID, args[1]); err != nil {
			return err
		}

		fmt.Printf("Route %q removed from sandbox %q.\n", args[1], sandbox.Name)
		return nil
	},
}
