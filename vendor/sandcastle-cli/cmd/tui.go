package cmd

import (
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/bubbles/key"
	"github.com/charmbracelet/bubbles/spinner"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/sandcastle/cli/api"
	"github.com/sandcastle/cli/internal/config"
)

// ---------- styles ----------

var (
	titleStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("214"))

	selectedStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("229")).
			Background(lipgloss.Color("57"))

	statusRunning = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))
	statusStopped = lipgloss.NewStyle().Foreground(lipgloss.Color("245"))

	helpStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("241"))
	errStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("196"))
	okStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("42"))

	headerStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("75"))

)

// ---------- views ----------

type tuiView int

const (
	viewSandboxes tuiView = iota
	viewRoutes
	viewCreateSandbox
	viewAddRoute
	viewConfirmDelete
	viewServers
	viewAddServer
	viewServerLogin
	viewConfirmRemoveServer
	viewSettings
)

// ---------- form field types ----------

type fieldKind int

const (
	fieldText fieldKind = iota
	fieldBool
	fieldCycle
)

type formField struct {
	label        string
	kind         fieldKind
	input        textinput.Model // for fieldText
	boolVal      bool            // for fieldBool
	defBool      bool            // default value (to show as dimmed when matching)
	cycleOptions []string        // for fieldCycle
	cycleIdx     int             // for fieldCycle — current selection
}

// ---------- messages ----------

type sandboxesLoadedMsg struct {
	sandboxes []api.Sandbox
	err       error
}

type routesLoadedMsg struct {
	routes []api.RouteResponse
	err    error
}

type snapshotsLoadedMsg struct {
	snapshots []api.Snapshot
	err       error
}

type actionDoneMsg struct {
	msg string
	err error
}

type deviceCodeMsg struct {
	code *api.DeviceCodeResponse
	err  error
}

type deviceTokenMsg struct {
	token   string
	pending bool
	err     error
}

// ---------- model ----------

type tuiModel struct {
	client *api.Client

	view     tuiView
	cursor   int
	width    int
	height   int
	spinner  spinner.Model
	loading  bool
	feedback string
	feedErr  bool

	// sandbox list
	sandboxes []api.Sandbox

	// routes
	routeSandbox *api.Sandbox
	routes       []api.RouteResponse
	routeCursor  int

	// create sandbox form
	createFields   []formField
	createCursor   int
	snapshots      []api.Snapshot // cached for snapshot name completion

	// add route
	routeInputs    [2]textinput.Model // domain, port
	routeFocusIdx  int

	// confirm delete
	deleteTarget string
	deleteID     int

	// server management
	servers       []serverEntry
	serverCursor  int
	addServerInputs [2]textinput.Model // URL, alias
	addServerFocus  int
	addServerInsecure bool

	// device auth login
	loginAlias      string
	loginURL        string
	loginInsecure   bool
	loginClient     *api.Client
	loginDeviceCode *api.DeviceCodeResponse
	loginPolling    bool
	loginUserCode   string
	loginVerifyURL  string

	// confirm remove server
	removeServerAlias string

	// settings
	settingsFields []formField
	settingsCursor int
}

type serverEntry struct {
	alias   string
	url     string
	active  bool
	hasToken bool
}

func makeTextInput(placeholder string, width int) textinput.Model {
	ti := textinput.New()
	ti.Placeholder = placeholder
	ti.CharLimit = 80
	ti.Width = width
	return ti
}

// Create form field indices — keep in sync with buildCreateFields.
const (
	cfName = iota
	cfImage
	cfSnapshot
	cfDocker
	cfVNC
	cfTailscale
	cfHome
	cfData
	cfSMB
	cfTemporary
	cfCount
)

func buildCreateFields() []formField {
	return []formField{
		{label: "Name", kind: fieldText, input: makeTextInput("leave empty for auto-generated name", 45)},
		{label: "Image", kind: fieldText, input: makeTextInput("ghcr.io/thieso2/sandcastle-sandbox:latest", 55)},
		{label: "Snapshot", kind: fieldText, input: makeTextInput("snapshot name to restore from", 45)},
		{label: "Docker", kind: fieldBool, boolVal: true, defBool: true},
		{label: "VNC", kind: fieldBool, boolVal: true, defBool: true},
		{label: "Tailscale", kind: fieldBool, boolVal: false, defBool: false},
		{label: "Home", kind: fieldBool, boolVal: false, defBool: false},
		{label: "Data path", kind: fieldText, input: makeTextInput("subpath or . for root (empty = none)", 45)},
		{label: "SMB", kind: fieldBool, boolVal: false, defBool: false},
		{label: "Temporary", kind: fieldBool, boolVal: false, defBool: false},
	}
}

// Settings form field indices — keep in sync with buildSettingsFields.
const (
	sfProtocol = iota
	sfTmux
	sfSSHArgs
	sfMountHome
	sfDataPath
	sfVNC
	sfDocker
)

func buildSettingsFields() []formField {
	cfg, _ := config.Load()
	prefs := cfg.LoadPreferences()

	// Protocol cycle
	protocolOpts := []string{"ssh", "mosh", "auto"}
	protocolIdx := 0
	for i, opt := range protocolOpts {
		raw := cfg.Preferences.ConnectProtocol
		if raw == "" {
			raw = "auto"
		}
		if opt == raw {
			protocolIdx = i
			break
		}
	}

	useTmux := true
	if prefs.UseTmux != nil {
		useTmux = *prefs.UseTmux
	}
	mountHome := false
	if prefs.MountHome != nil {
		mountHome = *prefs.MountHome
	}
	vnc := true
	if prefs.VNC != nil {
		vnc = *prefs.VNC
	}
	docker := true
	if prefs.Docker != nil {
		docker = *prefs.Docker
	}

	sshArgsInput := makeTextInput("extra flags for ssh/mosh", 45)
	sshArgsInput.SetValue(prefs.SSHExtraArgs)
	dataInput := makeTextInput(". for root, subpath, or empty for none", 45)
	dataInput.SetValue(prefs.DataPath)

	return []formField{
		{label: "Protocol", kind: fieldCycle, cycleOptions: protocolOpts, cycleIdx: protocolIdx},
		{label: "Tmux", kind: fieldBool, boolVal: useTmux, defBool: true},
		{label: "SSH extra args", kind: fieldText, input: sshArgsInput},
		{label: "Mount home", kind: fieldBool, boolVal: mountHome, defBool: false},
		{label: "Data path", kind: fieldText, input: dataInput},
		{label: "VNC", kind: fieldBool, boolVal: vnc, defBool: true},
		{label: "Docker", kind: fieldBool, boolVal: docker, defBool: true},
	}
}

func newTUI(client *api.Client) tuiModel {
	s := spinner.New()
	s.Spinner = spinner.Dot
	s.Style = lipgloss.NewStyle().Foreground(lipgloss.Color("214"))

	domainInput := makeTextInput("domain (e.g. app.example.com)", 40)
	portInput := makeTextInput("port (default 8080)", 10)
	portInput.CharLimit = 5

	return tuiModel{
		client:       client,
		spinner:      s,
		loading:      true,
		createFields: buildCreateFields(),
		routeInputs:  [2]textinput.Model{domainInput, portInput},
	}
}

func (m tuiModel) Init() tea.Cmd {
	return tea.Batch(m.spinner.Tick, loadSandboxes(m.client))
}

// ---------- commands ----------

func loadSandboxes(client *api.Client) tea.Cmd {
	return func() tea.Msg {
		sandboxes, err := client.ListSandboxes()
		return sandboxesLoadedMsg{sandboxes, err}
	}
}

func loadRoutes(client *api.Client, sandboxID int) tea.Cmd {
	return func() tea.Msg {
		routes, err := client.ListRoutes(sandboxID)
		return routesLoadedMsg{routes, err}
	}
}

func loadSnapshots(client *api.Client) tea.Cmd {
	return func() tea.Msg {
		snapshots, err := client.ListSnapshots()
		return snapshotsLoadedMsg{snapshots, err}
	}
}

func requestDeviceCode(client *api.Client) tea.Cmd {
	return func() tea.Msg {
		hostname, _ := os.Hostname()
		code, err := client.RequestDeviceCode(fmt.Sprintf("cli-%s", hostname))
		return deviceCodeMsg{code, err}
	}
}

func pollDeviceToken(client *api.Client, deviceCode string) tea.Cmd {
	return tea.Tick(3*time.Second, func(time.Time) tea.Msg {
		token, pending, err := client.PollDeviceToken(deviceCode)
		return deviceTokenMsg{token, pending, err}
	})
}

func doAction(fn func() (string, error)) tea.Cmd {
	return func() tea.Msg {
		msg, err := fn()
		return actionDoneMsg{msg, err}
	}
}

// ---------- update ----------

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil

	case spinner.TickMsg:
		var cmd tea.Cmd
		m.spinner, cmd = m.spinner.Update(msg)
		return m, cmd

	case sandboxesLoadedMsg:
		m.loading = false
		if msg.err != nil {
			m.feedback = msg.err.Error()
			m.feedErr = true
			return m, nil
		}
		m.sandboxes = msg.sandboxes
		if m.cursor >= len(m.sandboxes) {
			m.cursor = max(0, len(m.sandboxes)-1)
		}
		return m, nil

	case snapshotsLoadedMsg:
		if msg.err == nil {
			m.snapshots = msg.snapshots
		}
		return m, nil

	case routesLoadedMsg:
		m.loading = false
		if msg.err != nil {
			m.feedback = msg.err.Error()
			m.feedErr = true
			m.view = viewSandboxes
			return m, nil
		}
		m.routes = msg.routes
		m.routeCursor = 0
		return m, nil

	case deviceCodeMsg:
		if msg.err != nil {
			m.feedback = msg.err.Error()
			m.feedErr = true
			m.view = viewAddServer
			return m, nil
		}
		m.loginDeviceCode = msg.code
		m.loginUserCode = msg.code.UserCode
		m.loginVerifyURL = msg.code.VerificationURL
		m.loginPolling = true
		m.view = viewServerLogin
		// Try to open browser
		_ = tuiOpenBrowser(msg.code.VerificationURL)
		return m, pollDeviceToken(m.loginClient, msg.code.DeviceCode)

	case deviceTokenMsg:
		if msg.err != nil {
			m.feedback = msg.err.Error()
			m.feedErr = true
			m.loginPolling = false
			m.view = viewServers
			return m, nil
		}
		if msg.pending {
			// Keep polling
			return m, pollDeviceToken(m.loginClient, m.loginDeviceCode.DeviceCode)
		}
		// Success — save token and switch to the new server
		cfg, err := config.Load()
		if err != nil {
			m.feedback = err.Error()
			m.feedErr = true
		} else {
			cfg.SetServer(m.loginAlias, m.loginURL, msg.token, m.loginInsecure)
			if err := config.Save(cfg); err != nil {
				m.feedback = err.Error()
				m.feedErr = true
			} else {
				m.feedback = fmt.Sprintf("Logged in to %s", m.loginAlias)
				m.feedErr = false
				// Recreate client for the new server
				newClient, clientErr := api.NewClient()
				if clientErr == nil {
					m.client = newClient
				}
			}
		}
		m.loginPolling = false
		m.view = viewServers
		m.servers = loadServerList()
		return m, nil

	case actionDoneMsg:
		m.loading = false
		if msg.err != nil {
			m.feedback = msg.err.Error()
			m.feedErr = true
		} else {
			m.feedback = msg.msg
			m.feedErr = false
		}
		if m.view == viewConfirmDelete {
			m.view = viewSandboxes
		}
		// Reload context-appropriate data
		m.loading = true
		if m.view == viewRoutes && m.routeSandbox != nil {
			return m, tea.Batch(m.spinner.Tick, loadRoutes(m.client, m.routeSandbox.ID))
		}
		return m, tea.Batch(m.spinner.Tick, loadSandboxes(m.client))
	}

	switch m.view {
	case viewSandboxes:
		return m.updateSandboxes(msg)
	case viewRoutes:
		return m.updateRoutes(msg)
	case viewCreateSandbox:
		return m.updateCreate(msg)
	case viewAddRoute:
		return m.updateAddRoute(msg)
	case viewConfirmDelete:
		return m.updateConfirmDelete(msg)
	case viewServers:
		return m.updateServers(msg)
	case viewAddServer:
		return m.updateAddServer(msg)
	case viewServerLogin:
		return m.updateServerLogin(msg)
	case viewConfirmRemoveServer:
		return m.updateConfirmRemoveServer(msg)
	case viewSettings:
		return m.updateSettings(msg)
	}
	return m, nil
}

func (m tuiModel) updateSandboxes(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		m.feedback = ""
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("q", "ctrl+c"))):
			return m, tea.Quit
		case key.Matches(msg, key.NewBinding(key.WithKeys("up", "k"))):
			if m.cursor > 0 {
				m.cursor--
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("down", "j"))):
			if m.cursor < len(m.sandboxes)-1 {
				m.cursor++
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("c"))):
			m.view = viewCreateSandbox
			m.createFields = buildCreateFields()
			m.createCursor = 0
			m.createFields[0].input.Focus()
			cmds := []tea.Cmd{m.createFields[0].input.Cursor.BlinkCmd()}
			if len(m.snapshots) == 0 {
				cmds = append(cmds, loadSnapshots(m.client))
			}
			return m, tea.Batch(cmds...)
		case key.Matches(msg, key.NewBinding(key.WithKeys("r"))):
			if len(m.sandboxes) > 0 {
				m.loading = true
				m.feedback = ""
				sb := m.sandboxes[m.cursor]
				m.routeSandbox = &sb
				m.view = viewRoutes
				return m, tea.Batch(m.spinner.Tick, loadRoutes(m.client, sb.ID))
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("R"))):
			m.loading = true
			m.feedback = ""
			return m, tea.Batch(m.spinner.Tick, loadSandboxes(m.client))
		case key.Matches(msg, key.NewBinding(key.WithKeys("S"))):
			m.servers = loadServerList()
			m.serverCursor = 0
			// Position cursor on active server
			for i, s := range m.servers {
				if s.active {
					m.serverCursor = i
					break
				}
			}
			m.view = viewServers
			m.feedback = ""
			return m, nil
		case key.Matches(msg, key.NewBinding(key.WithKeys("P"))):
			m.settingsFields = buildSettingsFields()
			m.settingsCursor = 0
			m.view = viewSettings
			m.feedback = ""
			return m, nil
		case key.Matches(msg, key.NewBinding(key.WithKeys("s"))):
			if len(m.sandboxes) > 0 {
				sb := m.sandboxes[m.cursor]
				if sb.Status == "stopped" {
					m.loading = true
					return m, tea.Batch(m.spinner.Tick, doAction(func() (string, error) {
						_, err := m.client.StartSandbox(sb.ID)
						return fmt.Sprintf("%q started", sb.Name), err
					}))
				}
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("x"))):
			if len(m.sandboxes) > 0 {
				sb := m.sandboxes[m.cursor]
				if sb.Status == "running" {
					m.loading = true
					return m, tea.Batch(m.spinner.Tick, doAction(func() (string, error) {
						_, err := m.client.StopSandbox(sb.ID)
						return fmt.Sprintf("%q stopped", sb.Name), err
					}))
				}
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("d"))):
			if len(m.sandboxes) > 0 {
				sb := m.sandboxes[m.cursor]
				m.deleteTarget = sb.Name
				m.deleteID = sb.ID
				m.view = viewConfirmDelete
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("enter"))):
			// connect — exit TUI, then reconnect via the CLI connect command
			if len(m.sandboxes) > 0 {
				sb := m.sandboxes[m.cursor]
				exe, _ := os.Executable()
				c := exec.Command(exe, "connect", sb.Name)
				c.Stdin = os.Stdin
				c.Stdout = os.Stdout
				c.Stderr = os.Stderr
				return m, tea.ExecProcess(c, func(err error) tea.Msg {
					return actionDoneMsg{"", err}
				})
			}
		}
	}
	return m, nil
}

func (m tuiModel) updateRoutes(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		m.feedback = ""
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("q", "esc"))):
			m.view = viewSandboxes
			m.routes = nil
			m.routeSandbox = nil
		case key.Matches(msg, key.NewBinding(key.WithKeys("ctrl+c"))):
			return m, tea.Quit
		case key.Matches(msg, key.NewBinding(key.WithKeys("up", "k"))):
			if m.routeCursor > 0 {
				m.routeCursor--
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("down", "j"))):
			if m.routeCursor < len(m.routes)-1 {
				m.routeCursor++
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("a"))):
			m.view = viewAddRoute
			m.routeFocusIdx = 0
			m.routeInputs[0].SetValue("")
			m.routeInputs[1].SetValue("")
			m.routeInputs[0].Focus()
			m.routeInputs[1].Blur()
			return m, m.routeInputs[0].Cursor.BlinkCmd()
		case key.Matches(msg, key.NewBinding(key.WithKeys("d"))):
			if len(m.routes) > 0 {
				r := m.routes[m.routeCursor]
				sbID := m.routeSandbox.ID
				m.loading = true
				return m, tea.Batch(m.spinner.Tick, doAction(func() (string, error) {
					err := m.client.RemoveRouteByID(sbID, r.ID)
					return fmt.Sprintf("Route #%d removed", r.ID), err
				}))
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("R"))):
			if m.routeSandbox != nil {
				m.loading = true
				return m, tea.Batch(m.spinner.Tick, loadRoutes(m.client, m.routeSandbox.ID))
			}
		}
	}
	return m, nil
}

func (m tuiModel) createFocusField(idx int) (tuiModel, tea.Cmd) {
	// Blur all text fields, focus the target one
	for i := range m.createFields {
		if m.createFields[i].kind == fieldText {
			m.createFields[i].input.Blur()
		}
	}
	m.createCursor = idx
	if m.createFields[idx].kind == fieldText {
		m.createFields[idx].input.Focus()
		return m, m.createFields[idx].input.Cursor.BlinkCmd()
	}
	return m, nil
}

func (m tuiModel) updateCreate(msg tea.Msg) (tea.Model, tea.Cmd) {
	f := &m.createFields[m.createCursor]

	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEsc:
			m.view = viewSandboxes
			m.feedback = ""
			return m, nil
		case tea.KeyCtrlC:
			return m, tea.Quit
		case tea.KeyUp:
			if m.createCursor > 0 {
				return m.createFocusField(m.createCursor - 1)
			}
			return m, nil
		case tea.KeyDown, tea.KeyTab:
			if m.createCursor < len(m.createFields)-1 {
				return m.createFocusField(m.createCursor + 1)
			}
			return m, nil
		case tea.KeyShiftTab:
			if m.createCursor > 0 {
				return m.createFocusField(m.createCursor - 1)
			}
			return m, nil
		case tea.KeyEnter:
			if f.kind == fieldBool {
				// Toggle on enter too
				f.boolVal = !f.boolVal
				return m, nil
			}
			// Submit the form if on last field or ctrl+enter intent
			return m.submitCreateForm()
		case tea.KeyCtrlS:
			return m.submitCreateForm()
		}

		// Space toggles booleans
		if f.kind == fieldBool && msg.String() == " " {
			f.boolVal = !f.boolVal
			return m, nil
		}

		// Tab-completion for snapshot field
		if m.createCursor == cfSnapshot && f.kind == fieldText && msg.String() == "right" {
			m = m.completeSnapshot()
			return m, nil
		}
	}

	// Forward to text input if current field is text
	if f.kind == fieldText {
		var cmd tea.Cmd
		f.input, cmd = f.input.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m tuiModel) completeSnapshot() tuiModel {
	if len(m.snapshots) == 0 {
		return m
	}
	current := strings.ToLower(m.createFields[cfSnapshot].input.Value())
	for _, snap := range m.snapshots {
		if current == "" || strings.HasPrefix(strings.ToLower(snap.Name), current) {
			m.createFields[cfSnapshot].input.SetValue(snap.Name)
			m.createFields[cfSnapshot].input.CursorEnd()
			break
		}
	}
	return m
}

func (m tuiModel) submitCreateForm() (tea.Model, tea.Cmd) {
	name := strings.TrimSpace(m.createFields[cfName].input.Value())
	if name == "" {
		name = fmt.Sprintf("temp-%d", time.Now().Unix())
	}
	image := strings.TrimSpace(m.createFields[cfImage].input.Value())
	if image == "" {
		image = "ghcr.io/thieso2/sandcastle-sandbox:latest"
	}
	snapshot := strings.TrimSpace(m.createFields[cfSnapshot].input.Value())
	dataPath := strings.TrimSpace(m.createFields[cfData].input.Value())

	req := api.CreateSandboxRequest{
		Name:          name,
		Image:         image,
		FromSnapshot:  snapshot,
		DockerEnabled: m.createFields[cfDocker].boolVal,
		VNCEnabled:    m.createFields[cfVNC].boolVal,
		Tailscale:     m.createFields[cfTailscale].boolVal,
		MountHome:     m.createFields[cfHome].boolVal,
		DataPath:      dataPath,
		SMBEnabled:    m.createFields[cfSMB].boolVal,
		Temporary:     m.createFields[cfTemporary].boolVal,
	}

	m.view = viewSandboxes
	m.loading = true
	return m, tea.Batch(m.spinner.Tick, doAction(func() (string, error) {
		sb, err := m.client.CreateSandbox(req)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%q created", sb.Name), nil
	}))
}

func (m tuiModel) updateAddRoute(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEsc:
			m.view = viewRoutes
			return m, nil
		case tea.KeyCtrlC:
			return m, tea.Quit
		case tea.KeyTab, tea.KeyShiftTab:
			m.routeFocusIdx = (m.routeFocusIdx + 1) % 2
			for i := range m.routeInputs {
				if i == m.routeFocusIdx {
					m.routeInputs[i].Focus()
				} else {
					m.routeInputs[i].Blur()
				}
			}
			return m, m.routeInputs[m.routeFocusIdx].Cursor.BlinkCmd()
		case tea.KeyEnter:
			domain := strings.TrimSpace(m.routeInputs[0].Value())
			portStr := strings.TrimSpace(m.routeInputs[1].Value())
			if domain == "" {
				m.feedback = "domain is required"
				m.feedErr = true
				return m, nil
			}
			port := 8080
			if portStr != "" {
				n := 0
				for _, ch := range portStr {
					if ch < '0' || ch > '9' {
						m.feedback = "invalid port"
						m.feedErr = true
						return m, nil
					}
					n = n*10 + int(ch-'0')
				}
				port = n
			}
			sbID := m.routeSandbox.ID
			m.view = viewRoutes
			m.loading = true
			return m, tea.Batch(m.spinner.Tick, doAction(func() (string, error) {
				r, err := m.client.AddRoute(sbID, api.RouteRequest{
					Domain: domain,
					Port:   port,
					Mode:   "http",
				})
				if err != nil {
					return "", err
				}
				return fmt.Sprintf("Route added: %s → :%d", r.Domain, r.Port), nil
			}))
		}
	}

	var cmd tea.Cmd
	m.routeInputs[m.routeFocusIdx], cmd = m.routeInputs[m.routeFocusIdx].Update(msg)
	return m, cmd
}

func (m tuiModel) updateConfirmDelete(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("y", "Y"))):
			id := m.deleteID
			name := m.deleteTarget
			m.loading = true
			return m, tea.Batch(m.spinner.Tick, doAction(func() (string, error) {
				err := m.client.DestroySandbox(id)
				return fmt.Sprintf("%q destroyed", name), err
			}))
		default:
			m.view = viewSandboxes
			m.feedback = "cancelled"
			m.feedErr = false
		}
	}
	return m, nil
}

// ---------- view ----------

func (m tuiModel) View() string {
	var b strings.Builder

	title := titleStyle.Render("  Sandcastle")
	if m.client.ServerAlias != "" {
		title += helpStyle.Render(fmt.Sprintf("  %s", m.client.ServerAlias))
	}
	b.WriteString(title + "\n\n")

	switch m.view {
	case viewSandboxes:
		m.viewSandboxes(&b)
	case viewRoutes:
		m.viewRoutes(&b)
	case viewCreateSandbox:
		m.viewCreate(&b)
	case viewAddRoute:
		m.viewAddRoute(&b)
	case viewConfirmDelete:
		m.viewConfirmDelete(&b)
	case viewServers:
		m.viewServers(&b)
	case viewAddServer:
		m.viewAddServer(&b)
	case viewServerLogin:
		m.viewServerLogin(&b)
	case viewConfirmRemoveServer:
		m.viewConfirmRemoveServer(&b)
	case viewSettings:
		m.viewSettings(&b)
	}

	// Feedback
	if m.feedback != "" {
		b.WriteString("\n")
		if m.feedErr {
			b.WriteString(errStyle.Render("  " + m.feedback))
		} else {
			b.WriteString(okStyle.Render("  " + m.feedback))
		}
		b.WriteString("\n")
	}

	return b.String()
}

func (m tuiModel) viewSandboxes(b *strings.Builder) {
	if m.loading && len(m.sandboxes) == 0 {
		b.WriteString("  " + m.spinner.View() + " Loading sandboxes...\n")
		b.WriteString("\n" + helpStyle.Render("  q quit"))
		return
	}

	if len(m.sandboxes) == 0 {
		b.WriteString("  No sandboxes. Press c to create one.\n")
	} else {
		// Header
		b.WriteString(headerStyle.Render(fmt.Sprintf("  %-22s %-10s %-18s %s", "NAME", "STATUS", "CREATED", "ROUTE")) + "\n")

		for i, sb := range m.sandboxes {
			name := sb.Name
			if sb.Temporary {
				name += " ~"
			}
			if len(name) > 22 {
				name = name[:21] + "…"
			}

			st := statusStopped.Render(sb.Status)
			if sb.Status == "running" {
				st = statusRunning.Render(sb.Status)
			}

			created := sb.CreatedAt.Local().Format("Jan 02 15:04")

			route := ""
			if len(sb.Routes) > 0 {
				parts := make([]string, 0, len(sb.Routes))
				for _, r := range sb.Routes {
					if r.Mode == "tcp" {
						parts = append(parts, fmt.Sprintf("tcp/:%d", r.PublicPort))
					} else {
						parts = append(parts, r.Domain)
					}
				}
				route = strings.Join(parts, ", ")
				if len(route) > 30 {
					route = route[:29] + "…"
				}
			}

			line := fmt.Sprintf("  %-22s %-10s %-18s %s", name, st, created, route)
			if i == m.cursor {
				// Re-render with selection styling — pad to width
				padded := fmt.Sprintf("  %-22s %-20s %-18s %-30s", name, sb.Status, created, route)
				line = selectedStyle.Render(padded)
			}
			b.WriteString(line + "\n")
		}
	}

	if m.loading {
		b.WriteString("\n  " + m.spinner.View() + "\n")
	}

	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  enter connect  c create  s start  x stop  d destroy  r routes  S servers  P prefs  R refresh  q quit"))
	b.WriteString("\n")
}

func (m tuiModel) viewRoutes(b *strings.Builder) {
	b.WriteString(headerStyle.Render(fmt.Sprintf("  Routes for %s", m.routeSandbox.Name)) + "\n\n")

	if m.loading {
		b.WriteString("  " + m.spinner.View() + " Loading routes...\n")
		b.WriteString("\n" + helpStyle.Render("  esc back  q quit"))
		return
	}

	if len(m.routes) == 0 {
		b.WriteString("  No routes. Press a to add one.\n")
	} else {
		b.WriteString(headerStyle.Render(fmt.Sprintf("  %-6s %-6s %-30s %-8s %s", "ID", "MODE", "DOMAIN / PUBLIC PORT", "PORT", "URL")) + "\n")
		for i, r := range m.routes {
			target := r.Domain
			if r.Mode == "tcp" {
				target = fmt.Sprintf(":%d", r.PublicPort)
			}
			url := r.URL
			if len(url) > 40 {
				url = url[:39] + "…"
			}
			line := fmt.Sprintf("  %-6d %-6s %-30s %-8d %s", r.ID, r.Mode, target, r.Port, url)
			if i == m.routeCursor {
				line = selectedStyle.Render(fmt.Sprintf("  %-6d %-6s %-30s %-8d %-40s", r.ID, r.Mode, target, r.Port, url))
			}
			b.WriteString(line + "\n")
		}
	}

	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  a add  d delete  R refresh  esc/q back"))
	b.WriteString("\n")
}

var (
	formLabelStyle = lipgloss.NewStyle().
			Width(16).
			Foreground(lipgloss.Color("252"))

	formLabelActiveStyle = lipgloss.NewStyle().
				Width(16).
				Bold(true).
				Foreground(lipgloss.Color("214"))

	checkOn  = lipgloss.NewStyle().Foreground(lipgloss.Color("42")).Render("[x]")
	checkOff = lipgloss.NewStyle().Foreground(lipgloss.Color("245")).Render("[ ]")
)

func (m tuiModel) viewCreate(b *strings.Builder) {
	b.WriteString(headerStyle.Render("  Create Sandbox") + "\n\n")

	for i, f := range m.createFields {
		active := i == m.createCursor
		label := formLabelStyle.Render(f.label)
		if active {
			label = formLabelActiveStyle.Render(f.label)
		}

		cursor := "  "
		if active {
			cursor = "> "
		}

		switch f.kind {
		case fieldText:
			b.WriteString(fmt.Sprintf("%s%s %s", cursor, label, f.input.View()))
			// Show snapshot hints
			if i == cfSnapshot && len(m.snapshots) > 0 && active {
				current := strings.ToLower(f.input.Value())
				if current == "" {
					names := make([]string, 0, min(3, len(m.snapshots)))
					for j, s := range m.snapshots {
						if j >= 3 {
							break
						}
						names = append(names, s.Name)
					}
					hint := strings.Join(names, ", ")
					if len(m.snapshots) > 3 {
						hint += fmt.Sprintf(" (+%d more)", len(m.snapshots)-3)
					}
					b.WriteString("  " + helpStyle.Render(hint))
				}
			}
		case fieldBool:
			check := checkOff
			if f.boolVal {
				check = checkOn
			}
			b.WriteString(fmt.Sprintf("%s%s %s", cursor, label, check))
		}
		b.WriteString("\n")
	}

	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  arrows/tab navigate  space toggle  ctrl+s create  esc cancel"))
	b.WriteString("\n")
}

func (m tuiModel) viewAddRoute(b *strings.Builder) {
	b.WriteString(headerStyle.Render(fmt.Sprintf("  Add Route to %s", m.routeSandbox.Name)) + "\n\n")
	b.WriteString("  Domain: " + m.routeInputs[0].View() + "\n")
	b.WriteString("  Port:   " + m.routeInputs[1].View() + "\n")
	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  tab next field  enter confirm  esc cancel"))
	b.WriteString("\n")
}

func (m tuiModel) viewConfirmDelete(b *strings.Builder) {
	b.WriteString(errStyle.Render(fmt.Sprintf("  Destroy sandbox %q?", m.deleteTarget)) + "\n\n")
	b.WriteString("  Press y to confirm, any other key to cancel.\n")
}

// ---------- server management ----------

func loadServerList() []serverEntry {
	cfg, err := config.Load()
	if err != nil {
		return nil
	}
	aliases := make([]string, 0, len(cfg.Servers))
	for alias := range cfg.Servers {
		aliases = append(aliases, alias)
	}
	sort.Strings(aliases)

	entries := make([]serverEntry, 0, len(aliases))
	for _, alias := range aliases {
		srv := cfg.Servers[alias]
		entries = append(entries, serverEntry{
			alias:    alias,
			url:      srv.URL,
			active:   alias == cfg.CurrentServer,
			hasToken: srv.Token != "",
		})
	}
	return entries
}

func tuiDeriveAlias(serverURL string) string {
	u, err := url.Parse(serverURL)
	if err != nil {
		return "default"
	}
	host := u.Hostname()
	if host == "localhost" || host == "127.0.0.1" {
		return "local"
	}
	if net.ParseIP(host) != nil {
		return host
	}
	parts := strings.Split(host, ".")
	if len(parts) > 0 {
		return parts[0]
	}
	return "default"
}

func tuiOpenBrowser(url string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", url).Start()
	case "linux":
		return exec.Command("xdg-open", url).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
	default:
		return fmt.Errorf("unsupported platform")
	}
}

func (m tuiModel) updateServers(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		m.feedback = ""
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("q", "esc"))):
			m.view = viewSandboxes
			// Reload sandboxes in case server changed
			m.loading = true
			return m, tea.Batch(m.spinner.Tick, loadSandboxes(m.client))
		case key.Matches(msg, key.NewBinding(key.WithKeys("ctrl+c"))):
			return m, tea.Quit
		case key.Matches(msg, key.NewBinding(key.WithKeys("up", "k"))):
			if m.serverCursor > 0 {
				m.serverCursor--
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("down", "j"))):
			if m.serverCursor < len(m.servers)-1 {
				m.serverCursor++
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("enter"))):
			// Switch to selected server
			if len(m.servers) > 0 {
				s := m.servers[m.serverCursor]
				cfg, err := config.Load()
				if err != nil {
					m.feedback = err.Error()
					m.feedErr = true
					return m, nil
				}
				cfg.CurrentServer = s.alias
				if err := config.Save(cfg); err != nil {
					m.feedback = err.Error()
					m.feedErr = true
					return m, nil
				}
				// Recreate client
				newClient, clientErr := api.NewClient()
				if clientErr != nil {
					m.feedback = clientErr.Error()
					m.feedErr = true
					return m, nil
				}
				m.client = newClient
				m.servers = loadServerList()
				m.feedback = fmt.Sprintf("Switched to %s", s.alias)
				m.feedErr = false
			}
		case key.Matches(msg, key.NewBinding(key.WithKeys("a"))):
			// Add server
			m.view = viewAddServer
			m.addServerFocus = 0
			m.addServerInsecure = false
			urlInput := makeTextInput("https://sandcastle.example.com", 50)
			aliasInput := makeTextInput("auto-derived from URL", 30)
			urlInput.Focus()
			m.addServerInputs = [2]textinput.Model{urlInput, aliasInput}
			return m, urlInput.Cursor.BlinkCmd()
		case key.Matches(msg, key.NewBinding(key.WithKeys("d"))):
			// Remove server
			if len(m.servers) > 0 {
				m.removeServerAlias = m.servers[m.serverCursor].alias
				m.view = viewConfirmRemoveServer
			}
		}
	}
	return m, nil
}

func (m tuiModel) updateAddServer(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEsc:
			m.view = viewServers
			m.feedback = ""
			return m, nil
		case tea.KeyCtrlC:
			return m, tea.Quit
		case tea.KeyTab, tea.KeyDown:
			if m.addServerFocus < 2 {
				m.addServerFocus++
			}
			if m.addServerFocus < 2 {
				m.addServerInputs[0].Blur()
				m.addServerInputs[1].Blur()
				m.addServerInputs[m.addServerFocus].Focus()
				return m, m.addServerInputs[m.addServerFocus].Cursor.BlinkCmd()
			}
			// Focus is on insecure toggle — blur text inputs
			m.addServerInputs[0].Blur()
			m.addServerInputs[1].Blur()
			return m, nil
		case tea.KeyShiftTab, tea.KeyUp:
			if m.addServerFocus > 0 {
				m.addServerFocus--
			}
			if m.addServerFocus < 2 {
				m.addServerInputs[0].Blur()
				m.addServerInputs[1].Blur()
				m.addServerInputs[m.addServerFocus].Focus()
				return m, m.addServerInputs[m.addServerFocus].Cursor.BlinkCmd()
			}
			return m, nil
		case tea.KeyEnter:
			if m.addServerFocus == 2 {
				// Toggle insecure
				m.addServerInsecure = !m.addServerInsecure
				return m, nil
			}
			// Submit
			return m.submitAddServer()
		case tea.KeyCtrlS:
			return m.submitAddServer()
		}

		// Space on insecure toggle
		if m.addServerFocus == 2 && msg.String() == " " {
			m.addServerInsecure = !m.addServerInsecure
			return m, nil
		}
	}

	if m.addServerFocus < 2 {
		var cmd tea.Cmd
		m.addServerInputs[m.addServerFocus], cmd = m.addServerInputs[m.addServerFocus].Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m tuiModel) submitAddServer() (tea.Model, tea.Cmd) {
	serverURL := strings.TrimSpace(m.addServerInputs[0].Value())
	if serverURL == "" {
		m.feedback = "URL is required"
		m.feedErr = true
		return m, nil
	}
	serverURL = strings.TrimRight(serverURL, "/")

	alias := strings.TrimSpace(m.addServerInputs[1].Value())
	if alias == "" {
		alias = tuiDeriveAlias(serverURL)
	}

	m.loginAlias = alias
	m.loginURL = serverURL
	m.loginInsecure = m.addServerInsecure
	m.loginClient = api.NewClientWithToken(serverURL, "", m.addServerInsecure)
	m.view = viewServerLogin
	m.loginPolling = false
	m.loginUserCode = ""
	m.loginVerifyURL = ""
	m.feedback = ""

	return m, tea.Batch(m.spinner.Tick, requestDeviceCode(m.loginClient))
}

func (m tuiModel) updateServerLogin(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("esc", "ctrl+c"))):
			m.loginPolling = false
			m.view = viewServers
			m.feedback = "Login cancelled"
			m.feedErr = false
			return m, nil
		}
	}
	return m, nil
}

func (m tuiModel) updateConfirmRemoveServer(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch {
		case key.Matches(msg, key.NewBinding(key.WithKeys("y", "Y"))):
			alias := m.removeServerAlias
			cfg, err := config.Load()
			if err != nil {
				m.feedback = err.Error()
				m.feedErr = true
				m.view = viewServers
				return m, nil
			}
			delete(cfg.Servers, alias)
			if cfg.CurrentServer == alias {
				cfg.CurrentServer = ""
				for a := range cfg.Servers {
					cfg.CurrentServer = a
					break
				}
			}
			if err := config.Save(cfg); err != nil {
				m.feedback = err.Error()
				m.feedErr = true
			} else {
				m.feedback = fmt.Sprintf("Removed %s", alias)
				m.feedErr = false
				// Recreate client if server changed
				if newClient, err := api.NewClient(); err == nil {
					m.client = newClient
				}
			}
			m.servers = loadServerList()
			if m.serverCursor >= len(m.servers) {
				m.serverCursor = max(0, len(m.servers)-1)
			}
			m.view = viewServers
			return m, nil
		default:
			m.view = viewServers
			m.feedback = "cancelled"
			m.feedErr = false
		}
	}
	return m, nil
}

// ---------- server views ----------

var (
	serverActiveStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("42"))

	serverAuthStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("245"))

	codeStyle = lipgloss.NewStyle().
			Bold(true).
			Foreground(lipgloss.Color("229")).
			Background(lipgloss.Color("57")).
			Padding(0, 1)
)

func (m tuiModel) viewServers(b *strings.Builder) {
	b.WriteString(headerStyle.Render("  Servers") + "\n\n")

	if len(m.servers) == 0 {
		b.WriteString("  No servers configured. Press a to add one.\n")
	} else {
		b.WriteString(headerStyle.Render(fmt.Sprintf("  %-3s %-16s %-40s %s", "", "ALIAS", "URL", "STATUS")) + "\n")
		for i, s := range m.servers {
			marker := "   "
			if s.active {
				marker = serverActiveStyle.Render(" * ")
			}

			status := serverAuthStyle.Render("no token")
			if s.hasToken {
				status = okStyle.Render("authenticated")
			}

			alias := s.alias
			if len(alias) > 16 {
				alias = alias[:15] + "…"
			}
			surl := s.url
			if len(surl) > 40 {
				surl = surl[:39] + "…"
			}

			line := fmt.Sprintf("%s %-16s %-40s %s", marker, alias, surl, status)
			if i == m.serverCursor {
				line = selectedStyle.Render(fmt.Sprintf("%s %-16s %-40s %-15s", marker, alias, surl, func() string {
					if s.hasToken {
						return "authenticated"
					}
					return "no token"
				}()))
			}
			b.WriteString(line + "\n")
		}
	}

	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  enter select  a add  d remove  esc back"))
	b.WriteString("\n")
}

func (m tuiModel) viewAddServer(b *strings.Builder) {
	b.WriteString(headerStyle.Render("  Add Server") + "\n\n")

	labels := [3]string{"URL", "Alias", "Insecure"}
	for i := 0; i < 3; i++ {
		active := i == m.addServerFocus
		label := formLabelStyle.Render(labels[i])
		if active {
			label = formLabelActiveStyle.Render(labels[i])
		}
		cursor := "  "
		if active {
			cursor = "> "
		}

		if i < 2 {
			b.WriteString(fmt.Sprintf("%s%s %s\n", cursor, label, m.addServerInputs[i].View()))
		} else {
			check := checkOff
			if m.addServerInsecure {
				check = checkOn
			}
			b.WriteString(fmt.Sprintf("%s%s %s  %s\n", cursor, label, check, helpStyle.Render("skip TLS verification")))
		}
	}

	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  tab navigate  space toggle  ctrl+s/enter submit  esc cancel"))
	b.WriteString("\n")
}

func (m tuiModel) viewServerLogin(b *strings.Builder) {
	b.WriteString(headerStyle.Render(fmt.Sprintf("  Login to %s", m.loginAlias)) + "\n\n")

	if m.loginUserCode == "" {
		b.WriteString("  " + m.spinner.View() + " Requesting device code...\n")
	} else {
		b.WriteString("  Your code:  " + codeStyle.Render(m.loginUserCode) + "\n\n")
		b.WriteString("  Authorize at:\n")
		b.WriteString("  " + headerStyle.Render(m.loginVerifyURL) + "\n\n")
		b.WriteString("  " + m.spinner.View() + " Waiting for authorization...\n")
	}

	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  esc cancel"))
	b.WriteString("\n")
}

func (m tuiModel) viewConfirmRemoveServer(b *strings.Builder) {
	b.WriteString(errStyle.Render(fmt.Sprintf("  Remove server %q?", m.removeServerAlias)) + "\n\n")
	b.WriteString("  Press y to confirm, any other key to cancel.\n")
}

// ---------- settings ----------

func (m tuiModel) settingsFocusField(idx int) (tuiModel, tea.Cmd) {
	for i := range m.settingsFields {
		if m.settingsFields[i].kind == fieldText {
			m.settingsFields[i].input.Blur()
		}
	}
	m.settingsCursor = idx
	if m.settingsFields[idx].kind == fieldText {
		m.settingsFields[idx].input.Focus()
		return m, m.settingsFields[idx].input.Cursor.BlinkCmd()
	}
	return m, nil
}

func (m tuiModel) updateSettings(msg tea.Msg) (tea.Model, tea.Cmd) {
	f := &m.settingsFields[m.settingsCursor]

	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.Type {
		case tea.KeyEsc:
			m.view = viewSandboxes
			m.feedback = ""
			return m, nil
		case tea.KeyCtrlC:
			return m, tea.Quit
		case tea.KeyUp:
			if m.settingsCursor > 0 {
				return m.settingsFocusField(m.settingsCursor - 1)
			}
			return m, nil
		case tea.KeyDown, tea.KeyTab:
			if m.settingsCursor < len(m.settingsFields)-1 {
				return m.settingsFocusField(m.settingsCursor + 1)
			}
			return m, nil
		case tea.KeyShiftTab:
			if m.settingsCursor > 0 {
				return m.settingsFocusField(m.settingsCursor - 1)
			}
			return m, nil
		case tea.KeyEnter:
			if f.kind == fieldBool {
				f.boolVal = !f.boolVal
				return m, nil
			}
			if f.kind == fieldCycle {
				f.cycleIdx = (f.cycleIdx + 1) % len(f.cycleOptions)
				return m, nil
			}
			// On text field, save and exit
			return m.saveSettings()
		case tea.KeyCtrlS:
			return m.saveSettings()
		}

		// Space toggles booleans and cycles
		if msg.String() == " " {
			if f.kind == fieldBool {
				f.boolVal = !f.boolVal
				return m, nil
			}
			if f.kind == fieldCycle {
				f.cycleIdx = (f.cycleIdx + 1) % len(f.cycleOptions)
				return m, nil
			}
		}

		// Left/right for cycle fields
		if f.kind == fieldCycle {
			if msg.String() == "left" || msg.String() == "h" {
				f.cycleIdx = (f.cycleIdx - 1 + len(f.cycleOptions)) % len(f.cycleOptions)
				return m, nil
			}
			if msg.String() == "right" || msg.String() == "l" {
				f.cycleIdx = (f.cycleIdx + 1) % len(f.cycleOptions)
				return m, nil
			}
		}
	}

	if f.kind == fieldText {
		var cmd tea.Cmd
		f.input, cmd = f.input.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m tuiModel) saveSettings() (tea.Model, tea.Cmd) {
	cfg, err := config.Load()
	if err != nil {
		m.feedback = err.Error()
		m.feedErr = true
		return m, nil
	}

	// Protocol
	proto := m.settingsFields[sfProtocol].cycleOptions[m.settingsFields[sfProtocol].cycleIdx]
	if proto == "auto" {
		cfg.Preferences.ConnectProtocol = ""
	} else {
		cfg.Preferences.ConnectProtocol = proto
	}

	// Tmux
	tmux := m.settingsFields[sfTmux].boolVal
	cfg.Preferences.UseTmux = &tmux

	// SSH extra args
	cfg.Preferences.SSHExtraArgs = strings.TrimSpace(m.settingsFields[sfSSHArgs].input.Value())

	// Mount home
	home := m.settingsFields[sfMountHome].boolVal
	cfg.Preferences.MountHome = &home

	// Data path
	cfg.Preferences.DataPath = strings.TrimSpace(m.settingsFields[sfDataPath].input.Value())

	// VNC
	vnc := m.settingsFields[sfVNC].boolVal
	cfg.Preferences.VNC = &vnc

	// Docker
	docker := m.settingsFields[sfDocker].boolVal
	cfg.Preferences.Docker = &docker

	if err := config.Save(cfg); err != nil {
		m.feedback = err.Error()
		m.feedErr = true
		return m, nil
	}

	m.feedback = "Settings saved"
	m.feedErr = false
	m.view = viewSandboxes
	return m, nil
}

var (
	cycleActiveStyle = lipgloss.NewStyle().
				Bold(true).
				Foreground(lipgloss.Color("229")).
				Background(lipgloss.Color("57")).
				Padding(0, 1)

	cycleInactiveStyle = lipgloss.NewStyle().
				Foreground(lipgloss.Color("245")).
				Padding(0, 1)
)

func (m tuiModel) viewSettings(b *strings.Builder) {
	b.WriteString(headerStyle.Render("  Preferences") + "\n")
	b.WriteString(helpStyle.Render("  Defaults for new sandboxes and connections") + "\n\n")

	for i, f := range m.settingsFields {
		active := i == m.settingsCursor
		label := formLabelStyle.Render(f.label)
		if active {
			label = formLabelActiveStyle.Render(f.label)
		}
		cursor := "  "
		if active {
			cursor = "> "
		}

		switch f.kind {
		case fieldText:
			b.WriteString(fmt.Sprintf("%s%s %s", cursor, label, f.input.View()))
		case fieldBool:
			check := checkOff
			if f.boolVal {
				check = checkOn
			}
			b.WriteString(fmt.Sprintf("%s%s %s", cursor, label, check))
		case fieldCycle:
			b.WriteString(fmt.Sprintf("%s%s ", cursor, label))
			for j, opt := range f.cycleOptions {
				if j == f.cycleIdx {
					b.WriteString(cycleActiveStyle.Render(opt))
				} else {
					b.WriteString(cycleInactiveStyle.Render(opt))
				}
				if j < len(f.cycleOptions)-1 {
					b.WriteString(" ")
				}
			}
		}
		b.WriteString("\n")
	}

	b.WriteString("\n")
	b.WriteString(helpStyle.Render("  arrows/tab navigate  space/enter toggle  left/right cycle  ctrl+s save  esc cancel"))
	b.WriteString("\n")
}

// ---------- entry point ----------

func runTUI() error {
	client, err := api.NewClient()
	if err != nil {
		return err
	}

	p := tea.NewProgram(newTUI(client), tea.WithAltScreen())
	_, err = p.Run()
	return err
}
