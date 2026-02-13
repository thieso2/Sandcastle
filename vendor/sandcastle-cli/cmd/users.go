package cmd

import (
	"fmt"
	"os"
	"text/tabwriter"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
)

func init() {
	rootCmd.AddCommand(usersCmd)
	usersCmd.AddCommand(usersListCmd)
	usersCmd.AddCommand(usersCreateCmd)
	usersCmd.AddCommand(usersDestroyCmd)
}

var usersCmd = &cobra.Command{
	Use:   "users",
	Short: "Admin: manage users",
}

var usersListCmd = &cobra.Command{
	Use:     "list",
	Aliases: []string{"ls"},
	Short:   "List all users",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		users, err := client.ListUsers()
		if err != nil {
			return err
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
		fmt.Fprintln(w, "NAME\tEMAIL\tADMIN\tSANDBOXES\tSTATUS")
		for _, u := range users {
			admin := ""
			if u.Admin {
				admin = "yes"
			}
			fmt.Fprintf(w, "%s\t%s\t%s\t%d\t%s\n", u.Name, u.EmailAddress, admin, u.SandboxCount, u.Status)
		}
		w.Flush()
		return nil
	},
}

var usersCreateCmd = &cobra.Command{
	Use:   "create <name> <email> <password>",
	Short: "Create a new user",
	Args:  cobra.ExactArgs(3),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		user, err := client.CreateUser(api.CreateUserRequest{
			Name:                 args[0],
			EmailAddress:         args[1],
			Password:             args[2],
			PasswordConfirmation: args[2],
		})
		if err != nil {
			return err
		}

		fmt.Printf("User %q created (id: %d)\n", user.Name, user.ID)
		return nil
	},
}

var usersDestroyCmd = &cobra.Command{
	Use:   "destroy <name>",
	Short: "Destroy a user and their sandboxes",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}
		printServer(client)

		users, err := client.ListUsers()
		if err != nil {
			return err
		}

		var targetID int
		for _, u := range users {
			if u.Name == args[0] {
				targetID = u.ID
				break
			}
		}
		if targetID == 0 {
			return fmt.Errorf("user %q not found", args[0])
		}

		if err := client.DestroyUser(targetID); err != nil {
			return err
		}

		fmt.Printf("User %q destroyed.\n", args[0])
		return nil
	},
}
