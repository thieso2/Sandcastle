package cmd

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(serverCmd)
	serverCmd.AddCommand(serverAddCmd)
	serverCmd.AddCommand(serverListCmd)
	serverCmd.AddCommand(serverUseCmd)
	serverCmd.AddCommand(serverRemoveCmd)

	serverAddCmd.Flags().StringP("alias", "a", "", "Human-friendly alias for this server")
}

var serverCmd = &cobra.Command{
	Use:   "server",
	Short: "Manage server connections",
}

var serverAddCmd = &cobra.Command{
	Use:   "add <url>",
	Short: "Add a server",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		url := config.NormalizeURL(args[0])
		alias, _ := cmd.Flags().GetString("alias")

		// Check for duplicates.
		if existing := cfg.FindServer(url); existing != nil {
			return fmt.Errorf("server already exists: %s", url)
		}
		if alias != "" {
			if existing := cfg.FindServer(alias); existing != nil {
				return fmt.Errorf("alias already in use: %s", alias)
			}
		}

		entry := config.ServerEntry{
			Alias:  alias,
			Server: url,
		}
		cfg.AddServer(entry)

		if err := config.Save(cfg); err != nil {
			return err
		}

		if len(cfg.Servers) == 1 {
			fmt.Printf("Added server %s (set as current)\n", url)
		} else {
			fmt.Printf("Added server %s\n", url)
		}
		return nil
	},
}

var serverListCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List all servers",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		if len(cfg.Servers) == 0 {
			fmt.Println("No servers configured. Run: sandcastle server add <url>")
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "\tALIAS\tSERVER\tTOKEN")
		for _, s := range cfg.Servers {
			marker := " "
			if s.Alias == cfg.CurrentServer || s.Server == cfg.CurrentServer {
				marker = "*"
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", marker, s.Alias, s.Server, config.MaskToken(s.Token))
		}
		w.Flush()
		return nil
	},
}

var serverUseCmd = &cobra.Command{
	Use:   "use <alias-or-url>",
	Short: "Switch the active server",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		entry := cfg.FindServer(args[0])
		if entry == nil {
			return fmt.Errorf("server not found: %s", args[0])
		}

		if entry.Alias != "" {
			cfg.CurrentServer = entry.Alias
		} else {
			cfg.CurrentServer = entry.Server
		}

		if err := config.Save(cfg); err != nil {
			return err
		}

		fmt.Printf("Switched to %s\n", entry.Server)
		return nil
	},
}

var serverRemoveCmd = &cobra.Command{
	Use:   "remove <alias-or-url>",
	Short: "Remove a server",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}

		if err := cfg.RemoveServer(args[0]); err != nil {
			return err
		}

		if err := config.Save(cfg); err != nil {
			return err
		}

		fmt.Printf("Removed server %s\n", args[0])
		return nil
	},
}
