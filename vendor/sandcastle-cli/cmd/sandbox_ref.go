package cmd

import (
	"fmt"
	"sort"
	"strings"

	"github.com/sandcastle/cli/api"
)

type sandboxRef struct {
	Project string
	Name    string
	Scoped  bool
}

func parseSandboxRef(input string) (sandboxRef, error) {
	input = strings.TrimSpace(input)
	if input == "" {
		return sandboxRef{}, fmt.Errorf("sandbox name is required")
	}

	parts := strings.Split(input, ":")
	switch len(parts) {
	case 1:
		if parts[0] == "" {
			return sandboxRef{}, fmt.Errorf("invalid sandbox ref %q", input)
		}
		return sandboxRef{Name: parts[0]}, nil
	case 2:
		if parts[0] == "" || parts[1] == "" {
			return sandboxRef{}, fmt.Errorf("invalid sandbox ref %q: expected [project:]name", input)
		}
		return sandboxRef{Project: parts[0], Name: parts[1], Scoped: true}, nil
	default:
		return sandboxRef{}, fmt.Errorf("invalid sandbox ref %q: expected [project:]name", input)
	}
}

func resolveSandboxRef(sandboxes []api.Sandbox, input string) (*api.Sandbox, error) {
	ref, err := parseSandboxRef(input)
	if err != nil {
		return nil, err
	}

	if ref.Scoped {
		for i := range sandboxes {
			if sandboxes[i].ProjectName == ref.Project && sandboxes[i].Name == ref.Name {
				return &sandboxes[i], nil
			}
		}
		return nil, fmt.Errorf("sandbox %q not found", input)
	}

	matches := make([]api.Sandbox, 0, 1)
	for _, s := range sandboxes {
		if s.Name == ref.Name {
			matches = append(matches, s)
		}
	}
	if len(matches) == 0 {
		return nil, fmt.Errorf("sandbox %q not found", input)
	}
	if len(matches) == 1 {
		return &matches[0], nil
	}

	sort.Slice(matches, func(i, j int) bool {
		return sandboxSortKey(matches[i]) < sandboxSortKey(matches[j])
	})
	candidates := make([]string, len(matches))
	for i, s := range matches {
		candidates[i] = fmt.Sprintf("%s (id %d)", s.DisplayName(), s.ID)
	}
	return nil, fmt.Errorf("sandbox %q is ambiguous: %s", input, strings.Join(candidates, ", "))
}

func findSandboxByName(client *api.Client, name string) (*api.Sandbox, error) {
	sandboxes, err := client.ListSandboxes()
	if err != nil {
		return nil, err
	}
	return resolveSandboxRef(sandboxes, name)
}

func sortSandboxesForDisplay(sandboxes []api.Sandbox) {
	sort.SliceStable(sandboxes, func(i, j int) bool {
		return sandboxSortKey(sandboxes[i]) < sandboxSortKey(sandboxes[j])
	})
}

func sandboxSortKey(s api.Sandbox) string {
	project := s.ProjectName
	if project == "" {
		project = "\xff"
	}
	return project + "\x00" + s.Name
}

func displayProject(project string) string {
	if project == "" {
		return "-"
	}
	return project
}

func displayValue(value string) string {
	if value == "" {
		return "-"
	}
	return value
}

func sandboxDNSName(s api.Sandbox) string {
	if s.PrimaryDNSName != "" {
		return s.PrimaryDNSName
	}
	return s.Hostname
}
