# git-clone-all


How to Use:

Save: Save the script to a file, for example, github_clone_all.sh.

Make Executable: Open your terminal and run chmod +x github_clone_all.sh.

Get a PAT: Go to your GitHub settings -> Developer settings -> Personal access tokens -> Tokens (classic) -> Generate new token. Give it a name (e.g., repo-cloner) and select the repo scope (this grants full control of private repositories). Copy the generated token immediately – you won't see it again.

Run the Script:

```bash
./github_clone_all.sh <your_github_username> <your_copied_pat> /path/to/your/workspace
```
Replace <your_github_username>, <your_copied_pat>, and /path/to/your/desired/folder with your actual details.

Example:

bash
./github_clone_all.sh octocat ghp_YourVeryLongTokenHere ~/GitHubBackups
The script will then connect to GitHub, fetch the list of repositories for octocat, and clone each one into the ~/GitHubBackups directory, skipping any that already exist there.