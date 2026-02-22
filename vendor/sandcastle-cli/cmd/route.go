package cmd

import (
	"fmt"
	"os"
	"strconv"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

var routeAddTCP bool

func init() {
	rootCmd.AddCommand(routeCmd)
	routeCmd.AddCommand(routeAddCmd)
	routeCmd.AddCommand(routeListCmd)
	routeCmd.AddCommand(routeDeleteCmd)

	routeAddCmd.Flags().BoolVar(&routeAddTCP, "tcp", false, "Create a TCP port-forward route instead of HTTP")
}

var routeCmd = &cobra.Command{
	Use:   "route",
	Short: "Manage custom domain routes for a sandbox",
	Long: `Add, list, or remove custom domain routes for a sandbox.
Each sandbox can have multiple routes pointing to different ports.

Examples:
  sandcastle route add myapp app.example.com         # Add HTTP route (default port 8080)
  sandcastle route add myapp api.example.com 3000    # Add HTTP route on custom port
  sandcastle route add myapp --tcp 3000              # Add TCP forward to container port 3000
  sandcastle route list myapp                        # List all routes
  sandcastle route delete myapp app.example.com      # Remove an HTTP route by domain
  sandcastle route delete myapp --id 42              # Remove any route by ID`,
}

var routeAddCmd = &cobra.Command{
	Use:   "add <sandbox> [domain] [port]",
	Short: "Add a custom domain or TCP route",
	Args:  cobra.RangeArgs(1, 3),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		req := api.RouteRequest{}

		if routeAddTCP {
			// TCP mode: sandcastle route add <sandbox> --tcp <port>
			req.Mode = "tcp"
			port := 8080
			if len(args) >= 2 {
				port, err = strconv.Atoi(args[1])
				if err != nil {
					return fmt.Errorf("invalid port: %s", args[1])
				}
			}
			req.Port = port
		} else {
			// HTTP mode: sandcastle route add <sandbox> <domain> [port]
			if len(args) < 2 {
				return fmt.Errorf("HTTP routes require a domain argument")
			}
			req.Mode = "http"
			req.Domain = args[1]
			req.Port = 8080
			if len(args) == 3 {
				req.Port, err = strconv.Atoi(args[2])
				if err != nil {
					return fmt.Errorf("invalid port: %s", args[2])
				}
			}
		}

		route, err := client.AddRoute(sandbox.ID, req)
		if err != nil {
			return err
		}

		fmt.Printf("Route added for sandbox %q.\n", sandbox.Name)
		if route.Mode == "tcp" {
			fmt.Printf("  Mode:           TCP\n")
			fmt.Printf("  Public port:    %d\n", route.PublicPort)
			fmt.Printf("  Container port: %d\n", route.Port)
			fmt.Println("\nConnect via TCP: <host>:" + strconv.Itoa(route.PublicPort))
		} else {
			fmt.Printf("  Domain: %s\n", route.Domain)
			fmt.Printf("  Port:   %d\n", route.Port)
			fmt.Printf("  URL:    %s\n", route.URL)
			fmt.Println("\nPoint your DNS to this server, and Traefik will handle TLS automatically.")
		}
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
		printServer(client)

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
		fmt.Fprintln(w, "ID\tMODE\tDOMAIN / PUBLIC PORT\tCONTAINER PORT\tURL")
		for _, r := range routes {
			target := r.Domain
			if r.Mode == "tcp" {
				target = fmt.Sprintf(":%d", r.PublicPort)
			}
			fmt.Fprintf(w, "%d\t%s\t%s\t%d\t%s\n", r.ID, r.Mode, target, r.Port, r.URL)
		}
		w.Flush()
		return nil
	},
}

var routeDeleteID int

func init() {
	routeDeleteCmd.Flags().IntVar(&routeDeleteID, "id", 0, "Delete route by ID (works for both HTTP and TCP routes)")
}

var routeDeleteCmd = &cobra.Command{
	Use:   "delete <sandbox> [domain]",
	Short: "Remove a custom domain or TCP route",
	Args:  cobra.RangeArgs(1, 2),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		sandbox, err := findSandboxByName(client, args[0])
		if err != nil {
			return err
		}

		if routeDeleteID != 0 {
			if err := client.RemoveRouteByID(sandbox.ID, routeDeleteID); err != nil {
				return err
			}
			fmt.Printf("Route #%d removed from sandbox %q.\n", routeDeleteID, sandbox.Name)
			return nil
		}

		if len(args) < 2 {
			return fmt.Errorf("provide a domain argument or use --id <route-id>")
		}

		domain := args[1]
		if err := client.RemoveRoute(sandbox.ID, domain); err != nil {
			return err
		}

		fmt.Printf("Route %q removed from sandbox %q.\n", domain, sandbox.Name)
		return nil
	},
}
