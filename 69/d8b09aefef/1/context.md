# Session Context

## User Prompts

### Prompt 1

add a user setiing to add custimom links to display for each sandcastle. usage would be to allw adding a link like ssh://username:password@hostname:port with a name that will be available on the dashboard.
like  url: laterminal://open/{user}@{hostname} name:LaTerminal (allow more than one of those and also allow somethink like show on :[desktop/ipad/iphone/all]

### Prompt 2

how can we make the ssh conenction ereconnect to the default tmux session be default?

### Prompt 3

how about if i do not want a tmux session then?

### Prompt 4

yes

### Prompt 5

commit

### Prompt 6

two more things:
update the sandbox image to teh lastrest packages
make sure we can update claude inside a sandbox:
today we see (see log below) - we do not want claude to be installed in the users home but usr local bin. set the env so that claudes install localtion defaults to usr local bin

thies@thies-wild-viper:/persisted/IO/sensor$ claude --update
Current version: 2.1.71Checking for updates to latest version...Warning: Native installation exists but ~/.local/bin is not in your PATHFix...

