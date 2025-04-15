#!/usr/bin/env bash
set -e

# Directory where the runner will be installed
RUNNER_DIR="./actions-runner"

# Token file path
TOKEN_FILE="${RUNNER_DIR}/registration_token.txt"

# Set your environment variables here
GITHUB_OWNER="${GITHUB_OWNER:-my-org}"
GITHUB_REPO="${GITHUB_REPO:-my-repo}"
GITHUB_PAT="${GH_TOKEN:-YOUR_PAT_HERE}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname)-runner}"

# GitHub API token endpoint
TOKEN_ENDPOINT="https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/runners/registration-token"

echo "Acquiring ephemeral runner token..."
REG_TOKEN=$(curl -sX POST \
    -H "Authorization: token ${GITHUB_PAT}" \
    -H "Accept: application/vnd.github.v3+json" \
    "${TOKEN_ENDPOINT}" | jq -r .token)

if [[ -z "$REG_TOKEN" || "$REG_TOKEN" == "null" ]]; then
  echo "ERROR: Could not fetch runner token. Check your PAT scopes, owner/repo, or network."
  exit 1
fi

# Create runner dir and save token
mkdir -p "$RUNNER_DIR"
echo "$REG_TOKEN" > "$TOKEN_FILE"
echo "Registration token saved to ${TOKEN_FILE}"

# Write remove.sh into the dir
cat > "${RUNNER_DIR}/remove.sh" <<EOF
#!/usr/bin/env bash
set -e

TOKEN_FILE="\$(dirname "\$0")/registration_token.txt"

if [ -f "\$TOKEN_FILE" ]; then
  REG_TOKEN=\$(cat "\$TOKEN_FILE")
  echo "Deregistering runner..."
  "\$(dirname "\$0")/config.sh" remove --unattended --token "\$REG_TOKEN"
  echo "Runner deregistered."
  rm -f "\$TOKEN_FILE"
else
  echo "Error: Registration token not found at \$TOKEN_FILE."
  exit 1
fi
EOF
chmod +x "${RUNNER_DIR}/remove.sh"

echo "Fetching latest GitHub Actions runner..."
LATEST_URL=$(curl -s https://api.github.com/repos/actions/runner/releases/latest \
  | grep "browser_download_url" \
  | grep "linux-x64" \
  | cut -d '"' -f 4)

cd "$RUNNER_DIR"
curl -sL "$LATEST_URL" -o actions-runner.tar.gz
tar xzf actions-runner.tar.gz

echo "Configuring the runner with labels: self-hosted,coder,workspace,clubhut..."
./config.sh \
  --url "https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --work "_work" \
  --labels "self-hosted,coder,workspace,clubhut" \
  --unattended \
  --replace

