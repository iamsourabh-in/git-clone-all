#!/bin/bash

# --- Configuration ---
# Maximum number of repositories to fetch per API page (max 100)
PER_PAGE=100

# --- Helper Functions ---
usage() {
  echo "Usage: $0 <github_username> <github_pat>"
  echo "  <github_username> : The GitHub username whose repositories you want to manage."
  echo "  <github_pat>      : Your GitHub Personal Access Token (PAT) with 'repo' and 'delete_repo' scopes."
  echo ""
  echo "WARNING: This script permanently deletes repositories. Use with extreme caution."
  echo "         Ensure your PAT has the 'delete_repo' scope."
  exit 1
}

check_deps() {
  local missing_deps=0
  for cmd in curl jq; do
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
if [[ $# -ne 2 ]]; then
  usage
fi

USERNAME="$1"
PAT="$2"

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

# --- Fetch Repository List ---
echo "Fetching repository list for user '$USERNAME'..."
ALL_REPO_NAMES=()
API_URL="https://api.github.com/users/$USERNAME/repos?type=owner&sort=full_name&per_page=$PER_PAGE" # Fetch only owner repos, sorted

while [[ -n "$API_URL" ]]; do
  echo "Fetching from: $API_URL"
  response=$(curl -s -L -H "Accept: application/vnd.github.v3+json" \
                   -H "Authorization: token $PAT" \
                   -i "$API_URL") # -i includes headers

  # Separate headers and body
  headers=$(echo "$response" | sed '/^\r$/q')
  body=$(echo "$response" | sed '1,/^\r$/d')

  # Check for API errors in the body
  if echo "$body" | jq -e '.message' > /dev/null; then
     echo "Error fetching repositories:" >&2
     echo "$body" | jq '.' >&2
     # Display rate limit info if available in headers
     echo "$headers" | grep -i 'X-RateLimit' >&2
     # Check for specific auth errors
     if echo "$body" | jq -e '.message | test("Bad credentials")' > /dev/null; then
        echo "Hint: Check if your PAT is correct and has the 'repo' scope." >&2
     fi
     exit 1
  fi

  # Extract repo names from the current page's body using jq
  page_repos=($(echo "$body" | jq -r '.[] | select(.owner.login=="'$USERNAME'") | .name // empty')) # Ensure owner matches & handle nulls
  if [[ $? -ne 0 ]]; then
      echo "Error parsing JSON response with jq." >&2
      echo "Body received:" >&2
      echo "$body" >&2
      exit 1
  fi
  ALL_REPO_NAMES+=("${page_repos[@]}")

  # Find the 'next' link for pagination from headers
  next_link=$(echo "$headers" | grep -ioE '<[^>]+>;\s*rel="next"' | sed -E 's/<([^>]+)>;\s*rel="next"/\1/')
  API_URL="$next_link"
done

repo_count=${#ALL_REPO_NAMES[@]}
if [[ $repo_count -eq 0 ]]; then
  echo "No repositories found for user '$USERNAME' (or PAT lacks 'repo' scope)."
  exit 0
fi

echo "Found $repo_count repositories for '$USERNAME':"
echo "------------------------------------------"
# Display repositories with numbers
for i in "${!ALL_REPO_NAMES[@]}"; do
  printf "%3d. %s\n" $((i + 1)) "${ALL_REPO_NAMES[$i]}"
done
echo "------------------------------------------"

# --- User Selection ---
repos_to_delete_indices=()
repos_to_delete_names=()
while true; do
  read -p "Enter numbers of repos to delete (space-separated), or 'q' to quit: " -r selection
  if [[ "$selection" == "q" || "$selection" == "Q" ]]; then
    echo "Quitting without deleting."
    exit 0
  fi

  # Validate input are numbers within range
  valid_selection=true
  selected_indices_temp=()
  selected_names_temp=()
  for num in $selection; do
    if ! [[ "$num" =~ ^[0-9]+$ ]]; then
      echo "Error: '$num' is not a valid number." >&2
      valid_selection=false
      break
    fi
    index=$((num - 1)) # Convert to 0-based index
    if [[ $index -lt 0 || $index -ge $repo_count ]]; then
      echo "Error: Number '$num' is out of range (1-$repo_count)." >&2
      valid_selection=false
      break
    fi
    # Avoid duplicates in this selection round
    if [[ " ${selected_indices_temp[@]} " =~ " $index " ]]; then
       echo "Warning: Number '$num' (${ALL_REPO_NAMES[$index]}) selected multiple times. Will only process once." >&2
    else
       selected_indices_temp+=("$index")
       selected_names_temp+=("${ALL_REPO_NAMES[$index]}")
    fi
  done

  if [[ "$valid_selection" == true && ${#selected_indices_temp[@]} -gt 0 ]]; then
    repos_to_delete_indices=("${selected_indices_temp[@]}")
    repos_to_delete_names=("${selected_names_temp[@]}")
    break # Exit the loop if input is valid and not empty
  elif [[ "$valid_selection" == true && ${#selected_indices_temp[@]} -eq 0 ]]; then
     echo "No repositories selected. Please enter numbers or 'q'."
  fi
  # If invalid or empty, the loop continues
done

# --- Confirmation ---
echo ""
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "!!!           EXTREME DANGER ZONE           !!!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "You are about to PERMANENTLY DELETE the following repositories:"
for name in "${repos_to_delete_names[@]}"; do
  echo "  - $USERNAME/$name"
done
echo "This action CANNOT be undone."
echo "Ensure your PAT has the 'delete_repo' scope."
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
read -p "Type 'DELETE' (all caps) to confirm deletion: " confirmation

if [[ "$confirmation" != "DELETE" ]]; then
  echo "Confirmation failed. Aborting deletion."
  exit 1
fi

# --- Deletion Process ---
echo ""
echo "Proceeding with deletion..."
deleted_count=0
error_count=0

for index in "${repos_to_delete_indices[@]}"; do
  repo_to_delete="${ALL_REPO_NAMES[$index]}"
  delete_url="https://api.github.com/repos/$USERNAME/$repo_to_delete"

  echo "--- Deleting $USERNAME/$repo_to_delete ---"

  # Use curl -X DELETE. -f makes curl fail silently on server errors (we check status)
  # Use -w "%{http_code}" to get the HTTP status code
  http_status=$(curl -s -L -X DELETE \
       -H "Accept: application/vnd.github.v3+json" \
       -H "Authorization: token $PAT" \
       -w "%{http_code}" \
       -o /dev/null \
       "$delete_url")

  if [[ "$http_status" -eq 204 ]]; then # 204 No Content is success for DELETE
    echo "Successfully deleted $USERNAME/$repo_to_delete."
    ((deleted_count++))
  elif [[ "$http_status" -eq 403 ]]; then # Forbidden
     echo "Error: Failed to delete $USERNAME/$repo_to_delete (HTTP $http_status)." >&2
     echo "       Check if PAT has the 'delete_repo' scope." >&2
     ((error_count++))
  elif [[ "$http_status" -eq 404 ]]; then # Not Found
     echo "Error: Failed to delete $USERNAME/$repo_to_delete (HTTP $http_status)." >&2
     echo "       Repository might have already been deleted or name is incorrect." >&2
     ((error_count++))
  else
    echo "Error: Failed to delete $USERNAME/$repo_to_delete (HTTP $http_status)." >&2
    # You could add more specific error handling based on other status codes if needed
    ((error_count++))
  fi
  echo # Add a newline for readability
done

# --- Summary ---
echo "========================================"
echo "Deletion process finished."
echo "----------------------------------------"
echo " Repositories Selected: ${#repos_to_delete_names[@]}"
echo " Repositories Deleted:  $deleted_count"
echo " Deletion Errors:     $error_count"
echo "========================================"

# Exit with success code if no errors, otherwise non-zero
if [[ $error_count -gt 0 ]]; then
    exit 1
else
    exit 0
fi
