# Session Context

## User Prompts

### Prompt 1

for the arm64 image:

### Prompt 2

install offinial chrome for x86_64 - and install Chromium for aarch64 

like this:
# Debian-Schlüssel importieren
sudo apt-get install -y curl
curl -fsSL https://ftp-master.debian.org/keys/archive-key-12.asc | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/debian-archive.gpg

# Debian Testing repo hinzufügen
echo "deb [arch=arm64] http://deb.debian.org/debian testing main" | \
  sudo tee /etc/apt/sources.list.d/debian-testing.list

# Pin setzen, damit nicht alles von Debian gezogen wird
cat <<EO...

### Prompt 3

actually - don't use debian. use flatpak!
flatpak install flathub org.chromium.Chromium

### Prompt 4

commit this

