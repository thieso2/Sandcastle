package cmd

import (
	"bufio"
	"fmt"
	"os"
	"strings"

	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
	"github.com/spf13/cobra"
	"golang.org/x/term"
)

func init() {
	rootCmd.AddCommand(loginCmd)
}

var loginCmd = &cobra.Command{
	Use:   "login",
	Short: "Authenticate with email and password",
	RunE: func(cmd *cobra.Command, args []string) error {
		cfg, err := config.Load()
		if err != nil {
			return err
		}
		if cfg.Server == "" {
			return fmt.Errorf("server not configured — run: sandcastle config set-server <url>")
		}

		reader := bufio.NewReader(os.Stdin)

		fmt.Print("Email: ")
		email, _ := reader.ReadString('\n')
		email = strings.TrimSpace(email)

		fmt.Print("Password: ")
		passwordBytes, err := term.ReadPassword(int(os.Stdin.Fd()))
		if err != nil {
			return fmt.Errorf("reading password: %w", err)
		}
		fmt.Println()
		password := strings.TrimSpace(string(passwordBytes))

		client := api.NewClientWithToken(cfg.Server, "")
		token, err := client.CreateToken(api.CreateTokenRequest{
			EmailAddress: email,
			Password:     password,
			Name:         "cli-login",
		})
		if err != nil {
			return fmt.Errorf("login failed: %w", err)
		}

		cfg.Token = token.RawToken
		if err := config.Save(cfg); err != nil {
			return fmt.Errorf("saving token: %w", err)
		}

		fmt.Println("Logged in successfully.")
		return nil
	},
}
