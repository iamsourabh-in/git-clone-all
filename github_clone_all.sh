#!/bin/bash

# --- Configuration ---
# Maximum number of repositories to fetch per API page (max 100)
PER_PAGE=100

# --- Helper Functions ---
usage() {
  echo "Usage: $0 <github_username> <github_pat> <target_directory>"
  echo "  <github_username> : The GitHub username whose repositories you want to clone."
  echo "  <github_pat>      : Your GitHub Personal Access Token (PAT) with 'repo' scope."
  echo "  <target_directory>: The local directory where repositories will be cloned."
  exit 1
}

check_deps() {
  local missing_deps=0
  for cmd in curl jq git; do
    if ! command -v "$cmd" &> /dev/null; then
      echo "Error: Required command '$cmd' not found. Please install it." >&2
      missing_deps=1
    fi
  done
  if [[ "$missing_deps" -eq 1 ]]; then
    exit 1
  fi
}

# --- Argument Parsing ---
if [[ $# -ne 3 ]]; then
  usage
fi

USERNAME="$1"
PAT="$2"
TARGET_DIR="$3"

# --- Input Validation ---
check_deps

if [[ -z "$USERNAME" ]]; then
  echo "Error: GitHub username cannot be empty." >&2
  usage
fi
if [[ -z "$PAT" ]]; then
  echo "Error: GitHub PAT cannot be empty." >&2
  usage
fi
if [[ -z "$TARGET_DIR" ]]; then
  echo "Error: Target directory cannot be empty." >&2
  usage
fi

# --- Directory Setup ---
if [[ ! -d "$TARGET_DIR" ]]; then
  echo "Target directory '$TARGET_DIR' does not exist."
  read -p "Create it? (y/N): " create_dir
  if [[ "$create_dir" =~ ^[Yy]$ ]]; then
    mkdir -p "$TARGET_DIR"
    if [[ $? -ne 0 ]]; then
      echo "Error: Failed to create directory '$TARGET_DIR'." >&2
      exit 1
    fi
    echo "Directory '$TARGET_DIR' created."
  else
    echo "Exiting."
    exit 1
  fi
elif [[ ! -w "$TARGET_DIR" ]]; then
   echo "Error: Target directory '$TARGET_DIR' is not writable." >&2
   exit 1
fi

# --- Fetch Repository List ---
echo "Fetching repository list for user '$USERNAME'..."
ALL_REPO_URLS=()
API_URL="https://api.github.com/users/$USERNAME/repos?per_page=$PER_PAGE"

while [[ -n "$API_URL" ]]; do
  echo "Fetching from: $API_URL"
  # Fetch current page data and headers (-i includes headers)
  response=$(curl -s -L -H "Accept: application/vnd.github.v3+json" \
                   -H "Authorization: token $PAT" \
                   -i "$API_URL")

  # Separate headers and body
  headers=$(echo "$response" | sed '/^\r$/q')
  body=$(echo "$response" | sed '1,/^\r$/d')

  # Check for API errors in the body
  if echo "$body" | jq -e '.message' > /dev/null; then
     echo "Error fetching repositories:" >&2
     echo "$body" | jq '.' >&2
     # Display rate limit info if available in headers
     echo "$headers" | grep -i 'X-RateLimit' >&2
     exit 1
  fi

  # Extract clone URLs from the current page's body using jq
  page_urls=($(echo "$body" | jq -r '.[] | .clone_url // empty')) # Use // empty to handle nulls gracefully
  if [[ $? -ne 0 ]]; then
      echo "Error parsing JSON response with jq." >&2
      echo "Body received:" >&2
      echo "$body" >&2
      exit 1
  fi
  # Add URLs from this page to the main list
  ALL_REPO_URLS+=("${page_urls[@]}")

  # Find the 'next' link for pagination from headers
  next_link=$(echo "$headers" | grep -ioE '<[^>]+>;\s*rel="next"' | sed -E 's/<([^>]+)>;\s*rel="next"/\1/')

  # Update API_URL for the next iteration, loop terminates if next_link is empty
  API_URL="$next_link"
done

repo_count=${#ALL_REPO_URLS[@]}
if [[ $repo_count -eq 0 ]]; then
  echo "No repositories found for user '$USERNAME' (or PAT lacks permissions)."
  exit 0
fi

echo "Found $repo_count repositories."

# --- Clone Repositories ---
echo "Starting cloning process into '$TARGET_DIR'..."
original_dir=$(pwd)
cd "$TARGET_DIR" || exit 1 # Change to target dir, exit if fails

cloned_count=0
skipped_count=0
error_count=0

for repo_url in "${ALL_REPO_URLS[@]}"; do
  # Extract repo name (e.g., my-repo from https://github.com/user/my-repo.git)
  repo_name=$(basename "$repo_url" .git)

  echo "--- Processing repository: $repo_name ---"

  # Check if the directory already exists
  if [[ -d "$repo_name" ]]; then
    echo "Directory '$repo_name' already exists. Skipping."
    ((skipped_count++))
  else
    # Construct the authenticated URL (needed for private repos)
    # Format: https://<token>@github.com/user/repo.git
    auth_repo_url=$(echo "$repo_url" | sed "s|://|://$PAT@|")

    echo "Cloning '$repo_name'..."
    # Clone using the authenticated URL. Use --quiet for less verbose output during clone.
    if git clone --quiet "$auth_repo_url" "$repo_name"; then
      echo "Successfully cloned '$repo_name'."
      ((cloned_count++))
    else
      echo "Error: Failed to clone '$repo_name' from $repo_url" >&2
      ((error_count++))
      # Optional: Add more specific error handling here if needed
    fi
  fi
  echo # Add a newline for better readability between repos
done

# Go back to the original directory
cd "$original_dir" || exit 1

# --- Summary ---
echo "========================================"
echo "Cloning process finished."
echo " Target Directory: $TARGET_DIR"
echo "----------------------------------------"
echo " Repositories Found:  $repo_count"
echo " Repositories Cloned: $cloned_count"
echo " Repositories Skipped: $skipped_count"
echo " Cloning Errors:    $error_count"
echo "========================================"

# Exit with success code if no errors, otherwise non-zero
if [[ $error_count -gt 0 ]]; then
    exit 1
else
    exit 0
fi
