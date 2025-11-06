#!/usr/bin/env bash

set -e

JSON_MODE=false
SHORT_NAME=""
ARGS=()
i=0
while [ $i -lt $# ]; do
    arg="${!i}"
    case "$arg" in
        --json) 
            JSON_MODE=true 
            ;;
        --short-name)
            if [ $((i + 1)) -ge $# ]; then
                echo 'Error: --short-name requires a value' >&2
                exit 1
            fi
            i=$((i + 1))
            SHORT_NAME="${!i}"
            ;;
        --help|-h) 
            echo "Usage: $0 [--json] [--short-name <name>] <feature_description>"
            echo ""
            echo "Options:"
            echo "  --json              Output in JSON format"
            echo "  --short-name <name> Provide a custom branch name (descriptive, kebab-case)"
            echo "  --help, -h          Show this help message"
            echo ""
            echo "Branch naming:"
            echo "  - Any descriptive name works: user-auth, payment-fix, oauth-integration"
            echo "  - Numbers are optional: 001-user-auth or just user-auth"
            echo "  - Branch name becomes the specs/ folder name"
            echo ""
            echo "Examples:"
            echo "  $0 'Add user authentication system' --short-name 'user-auth'"
            echo "  $0 'Implement OAuth2 integration for API'"
            echo "  $0 --short-name '001-payment-fix' 'Fix payment processing bug'"
            exit 0
            ;;
        *) 
            ARGS+=("$arg") 
            ;;
    esac
    i=$((i + 1))
done

FEATURE_DESCRIPTION="${ARGS[*]}"
if [ -z "$FEATURE_DESCRIPTION" ]; then
    echo "Usage: $0 [--json] [--short-name <name>] <feature_description>" >&2
    exit 1
fi

# Function to find the repository root by searching for existing project markers
find_repo_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.git" ] || [ -d "$dir/.specify" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Resolve repository root. Prefer git information when available, but fall back
# to searching for repository markers so the workflow still functions in repositories that
# were initialised with --no-git.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if git rev-parse --show-toplevel >/dev/null 2>&1; then
    REPO_ROOT=$(git rev-parse --show-toplevel)
    HAS_GIT=true
else
    REPO_ROOT="$(find_repo_root "$SCRIPT_DIR")"
    if [ -z "$REPO_ROOT" ]; then
        echo "Error: Could not determine repository root. Please run this script from within the repository." >&2
        exit 1
    fi
    HAS_GIT=false
fi

cd "$REPO_ROOT"

SPECS_DIR="$REPO_ROOT/specs"
mkdir -p "$SPECS_DIR"

# Feature numbering is now optional
# If user wants numbers, they can include them in the short-name (e.g., --short-name "001-user-auth")
FEATURE_NUM=""

# Function to generate branch name with stop word filtering and length filtering
generate_branch_name() {
    local description="$1"
    
    # Common stop words to filter out
    local stop_words="^(i|a|an|the|to|for|of|in|on|at|by|with|from|is|are|was|were|be|been|being|have|has|had|do|does|did|will|would|should|could|can|may|might|must|shall|this|that|these|those|my|your|our|their|want|need|add|get|set)$"
    
    # Convert to lowercase and split into words
    local clean_name=$(echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/ /g')
    
    # Filter words: remove stop words and words shorter than 3 chars (unless they're uppercase acronyms in original)
    local meaningful_words=()
    for word in $clean_name; do
        # Skip empty words
        [ -z "$word" ] && continue
        
        # Keep words that are NOT stop words AND (length >= 3 OR are potential acronyms)
        if ! echo "$word" | grep -qiE "$stop_words"; then
            if [ ${#word} -ge 3 ]; then
                meaningful_words+=("$word")
            else
                # Keep short words if they appear as uppercase in original (likely acronyms)
                local word_upper=$(echo "$word" | tr '[:lower:]' '[:upper:]')
                if echo "$description" | grep -q "\b${word_upper}\b"; then
                    meaningful_words+=("$word")
                fi
            fi
        fi
    done
    
    # If we have meaningful words, use first 3-4 of them
    if [ ${#meaningful_words[@]} -gt 0 ]; then
        local max_words=3
        if [ ${#meaningful_words[@]} -eq 4 ]; then max_words=4; fi
        
        local result=""
        local count=0
        for word in "${meaningful_words[@]}"; do
            if [ $count -ge $max_words ]; then break; fi
            if [ -n "$result" ]; then result="$result-"; fi
            result="$result$word"
            count=$((count + 1))
        done
        echo "$result"
    else
        # Fallback to original logic if no meaningful words found
        echo "$description" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//' | sed 's/-$//' | tr '-' '\n' | grep -v '^$' | head -3 | tr '\n' '-' | sed 's/-$//'
    fi
}

# Generate branch name
if [ -n "$SHORT_NAME" ]; then
    # Use provided short name, just clean it up
    BRANCH_NAME=$(echo "$SHORT_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//' | sed 's/-$//')
else
    # Generate from description with smart filtering
    BRANCH_NAME=$(generate_branch_name "$FEATURE_DESCRIPTION")
fi

# GitHub enforces a 244-byte limit on branch names
# Validate and truncate if necessary
MAX_BRANCH_LENGTH=244
if [ ${#BRANCH_NAME} -gt $MAX_BRANCH_LENGTH ]; then
    # Truncate at word boundary if possible
    TRUNCATED_NAME=$(echo "$BRANCH_NAME" | cut -c1-$MAX_BRANCH_LENGTH)
    # Remove trailing hyphen if truncation created one
    TRUNCATED_NAME=$(echo "$TRUNCATED_NAME" | sed 's/-$//')
    
    ORIGINAL_BRANCH_NAME="$BRANCH_NAME"
    BRANCH_NAME="$TRUNCATED_NAME"
    
    >&2 echo "[specify] Warning: Branch name exceeded GitHub's 244-byte limit"
    >&2 echo "[specify] Original: $ORIGINAL_BRANCH_NAME (${#ORIGINAL_BRANCH_NAME} bytes)"
    >&2 echo "[specify] Truncated to: $BRANCH_NAME (${#BRANCH_NAME} bytes)"
fi

# Check if we're already on a feature branch with existing folder
CURRENT_BRANCH=""
if [ "$HAS_GIT" = true ]; then
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
fi

# Check if a folder already exists for the current branch
if [ -n "$CURRENT_BRANCH" ] && [ -d "$SPECS_DIR/$CURRENT_BRANCH" ]; then
    # Use existing branch and folder
    BRANCH_NAME="$CURRENT_BRANCH"
    FEATURE_DIR="$SPECS_DIR/$CURRENT_BRANCH"
    >&2 echo "[specify] Using existing branch: $CURRENT_BRANCH"
    >&2 echo "[specify] Using existing feature directory: $FEATURE_DIR"
elif [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "main" ] && [ "$CURRENT_BRANCH" != "master" ] && [ "$CURRENT_BRANCH" != "develop" ]; then
    # Already on a feature branch, just create the folder
    BRANCH_NAME="$CURRENT_BRANCH"
    FEATURE_DIR="$SPECS_DIR/$CURRENT_BRANCH"
    mkdir -p "$FEATURE_DIR"
    >&2 echo "[specify] Using existing branch: $CURRENT_BRANCH"
    >&2 echo "[specify] Created feature directory: $FEATURE_DIR"
else
    # Create new branch and folder
    if [ "$HAS_GIT" = true ]; then
        git checkout -b "$BRANCH_NAME"
        >&2 echo "[specify] Created new branch: $BRANCH_NAME"
    else
        >&2 echo "[specify] Warning: Git repository not detected; skipped branch creation for $BRANCH_NAME"
    fi
    FEATURE_DIR="$SPECS_DIR/$BRANCH_NAME"
    mkdir -p "$FEATURE_DIR"
    >&2 echo "[specify] Created feature directory: $FEATURE_DIR"
fi

TEMPLATE="$REPO_ROOT/.specify/templates/spec-template.md"
SPEC_FILE="$FEATURE_DIR/spec.md"
if [ ! -f "$SPEC_FILE" ]; then
    if [ -f "$TEMPLATE" ]; then cp "$TEMPLATE" "$SPEC_FILE"; else touch "$SPEC_FILE"; fi
    >&2 echo "[specify] Created spec file: $SPEC_FILE"
else
    >&2 echo "[specify] Using existing spec file: $SPEC_FILE"
fi

# Set the SPECIFY_FEATURE environment variable for the current session
export SPECIFY_FEATURE="$BRANCH_NAME"

if $JSON_MODE; then
    printf '{"BRANCH_NAME":"%s","SPEC_FILE":"%s"}\n' "$BRANCH_NAME" "$SPEC_FILE"
else
    echo "BRANCH_NAME: $BRANCH_NAME"
    echo "SPEC_FILE: $SPEC_FILE"
    echo "SPECIFY_FEATURE environment variable set to: $BRANCH_NAME"
fi