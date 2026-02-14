package cmd

import (
	"fmt"
	"os"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/sandcastle/cli/api"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func init() {
	rootCmd.AddCommand(tokenCmd)
	tokenCmd.AddCommand(tokenListCmd)
	tokenCmd.AddCommand(tokenCreateCmd)
	tokenCmd.AddCommand(tokenRevokeCmd)
}

var tokenCmd = &cobra.Command{
	Use:   "token",
	Short: "Manage API tokens",
	Long:  "Create, list, and revoke API tokens for Sandcastle CLI and API access.",
}

var tokenListCmd = &cobra.Command{
	Use:   "list",
	Short: "List all API tokens",
	RunE: func(cmd *cobra.Command, args []string) error {
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		tokens, err := client.ListTokens()
		if err != nil {
			return err
		}

		if len(tokens) == 0 {
			fmt.Println("No API tokens found.")
			fmt.Println("\nCreate a new token with: sandcastle token create <name>")
			return nil
		}

		w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
		fmt.Fprintln(w, "ID\tNAME\tPREFIX\tCREATED\tLAST USED")
		for _, t := range tokens {
			lastUsed := "Never"
			if t.LastUsedAt != nil {
				lastUsed = formatTimeAgo(*t.LastUsedAt)
			}
			created := formatTimeAgo(t.CreatedAt)
			fmt.Fprintf(w, "%d\t%s\t%s\t%s\t%s\n", t.ID, t.Name, t.Prefix, created, lastUsed)
		}
		w.Flush()

		return nil
	},
}

var tokenCreateCmd = &cobra.Command{
	Use:   "create <name>",
	Short: "Create a new API token",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		name := args[0]

		// Prompt for email and password
		fmt.Print("Email: ")
		var email string
		_, err := fmt.Scanln(&email)
		if err != nil {
			return fmt.Errorf("reading email: %w", err)
		}

		fmt.Print("Password: ")
		password, err := readPassword()
		if err != nil {
			return fmt.Errorf("reading password: %w", err)
		}
		fmt.Println() // newline after password input

		// Create client without token for authentication
		client, err := api.NewClient()
		if err != nil {
			return err
		}

		token, err := client.CreateToken(api.CreateTokenRequest{
			EmailAddress: email,
			Password:     password,
			Name:         name,
		})
		if err != nil {
			return err
		}

		fmt.Printf("\n✓ Created token '%s'\n\n", name)
		fmt.Printf("Token: %s\n\n", token.RawToken)
		fmt.Println("⚠️  Save this token now - you won't be able to see it again!")
		fmt.Println("\nTo use this token with the CLI:")
		fmt.Println("  sandcastle config set-token")

		return nil
	},
}

var tokenRevokeCmd = &cobra.Command{
	Use:   "revoke <id>",
	Short: "Revoke an API token",
	Args:  cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		var id int
		_, err := fmt.Sscanf(args[0], "%d", &id)
		if err != nil {
			return fmt.Errorf("invalid token ID: %s", args[0])
		}

		client, err := api.NewClient()
		if err != nil {
			return err
		}

		if err := client.DestroyToken(id); err != nil {
			return err
		}

		fmt.Printf("✓ Revoked token ID %d\n", id)
		return nil
	},
}

// formatTimeAgo returns a human-readable time ago string (e.g., "2 hours ago", "3 days ago")
func formatTimeAgo(t time.Time) string {
	duration := time.Since(t)

	switch {
	case duration < time.Minute:
		return "just now"
	case duration < time.Hour:
		mins := int(duration.Minutes())
		if mins == 1 {
			return "1 minute ago"
		}
		return fmt.Sprintf("%d minutes ago", mins)
	case duration < 24*time.Hour:
		hours := int(duration.Hours())
		if hours == 1 {
			return "1 hour ago"
		}
		return fmt.Sprintf("%d hours ago", hours)
	case duration < 30*24*time.Hour:
		days := int(duration.Hours() / 24)
		if days == 1 {
			return "1 day ago"
		}
		return fmt.Sprintf("%d days ago", days)
	case duration < 365*24*time.Hour:
		months := int(duration.Hours() / 24 / 30)
		if months == 1 {
			return "1 month ago"
		}
		return fmt.Sprintf("%d months ago", months)
	default:
		years := int(duration.Hours() / 24 / 365)
		if years == 1 {
			return "1 year ago"
		}
		return fmt.Sprintf("%d years ago", years)
	}
}

// readPassword reads a password from stdin without echoing it
func readPassword() (string, error) {
	bytePassword, err := term.ReadPassword(int(syscall.Stdin))
	if err != nil {
		return "", err
	}
	return string(bytePassword), nil
}
