#!/bin/bash

# Fetch more git history to ensure we have enough context
git fetch --unshallow origin master develop || git fetch origin master develop

# Get the current branch name
current_branch=$(git rev-parse --abbrev-ref HEAD)
echo "Current branch: $current_branch"
echo

# First try to find common ancestor with master
master_ancestor=$(git merge-base master "$current_branch" 2>/dev/null)
develop_ancestor=$(git merge-base develop "$current_branch" 2>/dev/null)

echo "Master ancestor commit: $master_ancestor"
echo "Develop ancestor commit: $develop_ancestor"
echo

# Determine which is the parent branch
if [ -n "$master_ancestor" ] && [ -n "$develop_ancestor" ]; then
   # Both exist, so compare their timestamps to find the more recent one
   master_timestamp=$(git show -s --format=%ct "$master_ancestor")
   develop_timestamp=$(git show -s --format=%ct "$develop_ancestor")

   echo "Master ancestor timestamp: $master_timestamp"
   echo "Develop ancestor timestamp: $develop_timestamp"
   echo

   if [ "$master_timestamp" -gt "$develop_timestamp" ]; then
       parent_branch="master"
       ancestor=$master_ancestor
       echo "Selected [master] as parent (more recent timestamp)"
   else
       parent_branch="develop"
       ancestor=$develop_ancestor
       echo "Selected [develop] as parent (more recent timestamp)"
   fi
elif [ -n "$master_ancestor" ]; then
   parent_branch="master"
   ancestor=$master_ancestor
   echo "Selected master as parent (only ancestor found)"
elif [ -n "$develop_ancestor" ]; then
   parent_branch="develop"
   ancestor=$develop_ancestor
   echo "Selected develop as parent (only ancestor found)"
else
   echo "Error: Branch is not based on either master or develop"
   exit 1
fi
echo

# Count commits between ancestor and current branch head
commit_count=$(git rev-list --count "$ancestor..$current_branch")

echo "Parent branch is: $parent_branch"
echo "Ancestor commit: $ancestor"
echo "Number of new commits: $commit_count"
echo

# Return 0 if there are new commits, 1 if there aren't
if [ "$commit_count" -gt 0 ]; then
   echo "New commits found"
   exit 0
else
   echo "No new commits"
   exit 1
fi