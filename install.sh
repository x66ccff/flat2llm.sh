#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  flat2llm — Flatten a codebase into a single text for LLMs     ║
# ║  Version : 1.2.0                                                ║
# ║  License : MIT                                                  ║
# ╚══════════════════════════════════════════════════════════════════╝
set -euo pipefail

VERSION="1.2.0"
SCRIPT_NAME="flat2llm"
INSTALL_DIR="$HOME/scripts"

# ─── Defaults ──────────────────────────────────────────────────────
TARGET_DIR=""
OUTPUT_FILE="flat_output.txt"
MAX_SIZE_KB=100
COPY_CLIPBOARD=false
TREE_ONLY=false

# ─── Colors (only when stdout is a terminal) ──────────────────────
if [[ -t 1 ]]; then
    RED='\033[0;31m';    GREEN='\033[0;32m';  YELLOW='\033[1;33m'
    BLUE='\033[0;34m';   MAGENTA='\033[0;35m'; CYAN='\033[0;36m'
    WHITE='\033[1;37m';  DIM='\033[2m';        BOLD='\033[1m'
    RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''
    WHITE=''; DIM=''; BOLD=''; RESET=''
fi

# ─── Directories to ignore (pruned by find) ──────────────────────
IGNORE_DIRS=(
    .git .svn .hg
    node_modules vendor bower_components jspm_packages
    __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox
    .venv venv env .env .nox
    .idea .vscode .eclipse .settings .project
    dist build out target bin obj release
    .next .nuxt .cache .parcel-cache .turbo
    coverage .nyc_output .c8_output .coverage
    .terraform .serverless .aws-sam .amplify
    .gradle .m2 .cargo
    .docker .vagrant
    logs tmp temp
)

# ─── File extensions to ignore ────────────────────────────────────
IGNORE_EXTENSIONS=(
    # Compiled / Binary
    pyc pyo class o so dylib dll exe a lib obj wasm
    # Images
    jpg jpeg png gif bmp ico svg webp tiff tif psd ai eps raw cr2 nef avif
    # Audio / Video
    mp3 mp4 avi mov wav flac ogg wmv mkv webm m4a aac wma
    # Archives
    zip tar gz bz2 rar 7z xz zst lz4 cab iso dmg jar war ear apk ipa
    # Documents (binary format)
    pdf doc docx xls xlsx ppt pptx odt ods odp rtf
    # Fonts
    woff woff2 ttf eot otf
    # Database
    db sqlite sqlite3 mdb accdb
    # Misc binary / data
    bin dat pak bundle img hdf5 h5 npy npz pkl pickle parquet arrow feather
    # Source maps
    map
)

# ─── Exact filenames to ignore ────────────────────────────────────
IGNORE_FILES=(
    .DS_Store Thumbs.db desktop.ini .gitkeep .gitattributes
    package-lock.json yarn.lock pnpm-lock.yaml
    composer.lock Gemfile.lock Cargo.lock
    poetry.lock go.sum flake.lock bun.lockb
    .eslintcache .prettiercache
    .terraform.lock.hcl
)

# ═══════════════════════════════════════════════════════════════════
#  Utility Functions
# ═══════════════════════════════════════════════════════════════════

info()    { echo -e "${CYAN}ℹ${RESET}  $*"; }
success() { echo -e "${GREEN}✓${RESET}  $*"; }
warn()    { echo -e "${YELLOW}⚠${RESET}  $*"; }
error()   { echo -e "${RED}✖${RESET}  $*" >&2; }

# Detect binary files using `file` command + null-byte fallback
is_binary() {
    local f="$1"
    [[ ! -f "$f" ]] && return 0
    # Fast path: check MIME type
    local mime
    mime=$(file -bL --mime-type "$f" 2>/dev/null || echo "unknown")
    case "$mime" in
        text/*|application/json|application/xml|application/javascript|\
        application/x-sh|application/x-shellscript|application/x-ruby|\
        application/x-perl|application/x-php|application/x-awk|\
        application/toml|application/yaml|application/x-yaml|\
        application/x-httpd-php|inode/x-empty|application/x-empty)
            return 1 ;;   # NOT binary
    esac
    # Fallback: check for null bytes in first 8 KB
    if head -c 8192 "$f" 2>/dev/null | LC_ALL=C grep -qP '\x00' 2>/dev/null; then
        return 0  # binary
    fi
    return 1  # assume text
}

# Check if a filename matches ignore rules (name + extension)
should_ignore_file() {
    local name="$1"
    # Exact name match
    for f in "${IGNORE_FILES[@]}"; do
        [[ "$name" == "$f" ]] && return 0
    done
    # Extension match
    local ext="${name##*.}"
    if [[ "$ext" != "$name" ]]; then
        ext="${ext,,}"  # lowercase
        for e in "${IGNORE_EXTENSIONS[@]}"; do
            [[ "$ext" == "$e" ]] && return 0
        done
    fi
    # Minified / bundled patterns
    case "$name" in
        *.min.js|*.min.css|*.bundle.js|*.chunk.js|*.min.map) return 0 ;;
    esac
    return 1
}

# ═══════════════════════════════════════════════════════════════════
#  Tree Generation (pure bash fallback)
# ═══════════════════════════════════════════════════════════════════

_tree_recurse() {
    local dir="$1" prefix="$2" max_depth="$3" current_depth="${4:-0}"
    [[ $current_depth -ge $max_depth ]] && return

    local -a items=()
    while IFS= read -r -d '' entry; do
        items+=("$entry")
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -print0 2>/dev/null | sort -z)

    # Pre-filter to get correct count for └── detection
    local -a filtered=()
    for item in "${items[@]}"; do
        local name
        name=$(basename "$item")
        # Skip ignored directories
        if [[ -d "$item" ]]; then
            local skip=false
            for d in "${IGNORE_DIRS[@]}"; do
                [[ "$name" == "$d" ]] && { skip=true; break; }
            done
            $skip && continue
        fi
        # Skip ignored files
        if [[ -f "$item" ]]; then
            should_ignore_file "$name" && continue
        fi
        # Skip symlinks
        [[ -L "$item" ]] && continue
        filtered+=("$item")
    done

    local total=${#filtered[@]}
    local idx=0
    for item in "${filtered[@]}"; do
        idx=$((idx + 1))
        local name
        name=$(basename "$item")
        local connector="├── "
        local next_prefix="${prefix}│   "
        if [[ $idx -eq $total ]]; then
            connector="└── "
            next_prefix="${prefix}    "
        fi
        if [[ -d "$item" ]]; then
            echo "${prefix}${connector}${name}/"
            _tree_recurse "$item" "$next_prefix" "$max_depth" $((current_depth + 1))
        else
            echo "${prefix}${connector}${name}"
        fi
    done
}

generate_tree() {
    local dir="$1"
    local base
    base=$(basename "$(realpath "$dir")")
    echo "${base}/"
    _tree_recurse "$dir" "" 20
}

# ═══════════════════════════════════════════════════════════════════
#  File Collection
# ═══════════════════════════════════════════════════════════════════

collect_files() {
    local dir="$1"

    # Build -prune expression for find
    local -a prune_expr=(\()
    local first=true
    for d in "${IGNORE_DIRS[@]}"; do
        if $first; then
            prune_expr+=(-name "$d")
            first=false
        else
            prune_expr+=(-o -name "$d")
        fi
    done
    prune_expr+=(\) -prune)

    find "$dir" "${prune_expr[@]}" -o -type f -print 2>/dev/null | sort | while IFS= read -r file; do
        local name
        name=$(basename "$file")

        # Skip by name/extension
        should_ignore_file "$name" && continue

        # Skip symlinks
        [[ -L "$file" ]] && continue

        # Skip by file size
        local size
        size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
        [[ $size -gt $((MAX_SIZE_KB * 1024)) ]] && continue

        # Skip empty files
        [[ $size -eq 0 ]] && continue

        # Skip binary files
        is_binary "$file" && continue

        echo "$file"
    done
}

# ═══════════════════════════════════════════════════════════════════
#  Output Generation
# ═══════════════════════════════════════════════════════════════════

generate_output() {
    local dir="$1"
    local outfile="$2"
    local tmplist
    tmplist=$(mktemp)
    trap "rm -f '$tmplist'" RETURN

    local abs_dir
    abs_dir=$(realpath "$dir")

    info "Scanning ${BOLD}${abs_dir}${RESET} ..."

    # Collect files
    collect_files "$dir" > "$tmplist"
    local file_count
    file_count=$(wc -l < "$tmplist")

    if [[ $file_count -eq 0 ]]; then
        warn "No files found after filtering."
        return 1
    fi

    info "Found ${BOLD}${file_count}${RESET} files to include."

    # Calculate total size
    local total_bytes=0
    while IFS= read -r f; do
        local s
        s=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
        total_bytes=$((total_bytes + s))
    done < "$tmplist"
    local total_kb=$(( (total_bytes + 1023) / 1024 ))

    # Start writing output
    {
        # ─── Header ───
        echo "# Codebase Snapshot"
        echo "# Generated by ${SCRIPT_NAME} v${VERSION}"
        echo "# Date: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "# Source: ${abs_dir}"
        echo "# Files: ${file_count} | Total Size: ${total_kb} KB | Max Per-File: ${MAX_SIZE_KB} KB"
        echo ""

        # ─── Tree ───
        local sep="================================================================================"
        echo "$sep"
        echo "  PROJECT STRUCTURE"
        echo "$sep"
        echo ""
        generate_tree "$dir"
        echo ""

        # ─── File Contents ───
        local idx=0
        while IFS= read -r file; do
            idx=$((idx + 1))
            local relpath="${file#$dir/}"
            [[ "$relpath" == "$file" ]] && relpath="${file#$dir}"  # handle edge cases

            echo "$sep"
            echo "  File: ${relpath}"
            echo "$sep"
            echo ""
            cat "$file" 2>/dev/null || echo "[ERROR: Could not read file]"
            echo ""
        done < "$tmplist"

        echo "$sep"
        echo "  END OF SNAPSHOT (${file_count} files, ${total_kb} KB)"
        echo "$sep"

    } > "$outfile"

    local out_size
    out_size=$(stat -c%s "$outfile" 2>/dev/null || stat -f%z "$outfile" 2>/dev/null || echo 0)
    local out_kb=$(( (out_size + 1023) / 1024 ))

    echo ""
    success "Output written to ${BOLD}${outfile}${RESET}"
    success "Output size: ${BOLD}${out_kb} KB${RESET} (${file_count} files)"

    # Optional: copy to clipboard
    if $COPY_CLIPBOARD; then
        if command -v pbcopy &>/dev/null; then
            cat "$outfile" | pbcopy
            success "Copied to clipboard (pbcopy)"
        elif command -v xclip &>/dev/null; then
            cat "$outfile" | xclip -selection clipboard
            success "Copied to clipboard (xclip)"
        elif command -v xsel &>/dev/null; then
            cat "$outfile" | xsel --clipboard --input
            success "Copied to clipboard (xsel)"
        elif command -v wl-copy &>/dev/null; then
            cat "$outfile" | wl-copy
            success "Copied to clipboard (wl-copy)"
        else
            warn "No clipboard tool found (tried pbcopy, xclip, xsel, wl-copy)"
        fi
    fi
}

# ═══════════════════════════════════════════════════════════════════
#  TUI — Interactive Text UI
# ═══════════════════════════════════════════════════════════════════

tui_clear() { printf '\033[2J\033[H'; }

tui_banner() {
    echo -e "${CYAN}"
    cat << 'BANNER'
  ╔════════════════════════════════════════════════════════════════════════╗
  ║                                                                        ║
  ║   ███████╗██╗      █████╗ ████████╗██████╗ ██╗     ██╗     ███╗ ███╗   ║
  ║   ██╔════╝██║     ██╔══██╗╚══██╔══╝╚════██╗██║     ██║     ████╗████║  ║
  ║   █████╗  ██║     ███████║   ██║    █████╔╝██║     ██║     ██╔████╔██║ ║
  ║   ██╔══╝  ██║     ██╔══██║   ██║   ██╔═══╝ ██║     ██║     ██║╚██╔╝██║ ║
  ║   ██║     ███████╗██║  ██║   ██║   ███████╗███████╗███████╗██║ ╚═╝ ██║ ║
  ║   ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚══════╝╚══════╝╚═╝     ╚═╝ ║
  ║                                                                        ║
  ║   Flatten codebase → single text → paste to LLM                        ║
  ╚════════════════════════════════════════════════════════════════════════╝
BANNER
    echo -e "${RESET}"
    echo -e "    ${DIM}v${VERSION}${RESET}"
    echo ""
}

tui_show_menu() {
    local dir_display="${TARGET_DIR:-.}"
    echo -e "  ${BOLD}Current Settings${RESET}"
    echo -e "  ─────────────────────────────────────────────────────"
    printf "  ${WHITE}[1]${RESET} %-22s → ${BOLD}%s${RESET}\n" "Target Directory" "$dir_display"
    printf "  ${WHITE}[2]${RESET} %-22s → ${BOLD}%s${RESET}\n" "Output File" "$OUTPUT_FILE"
    printf "  ${WHITE}[3]${RESET} %-22s → ${BOLD}%s${RESET}\n" "Max File Size (KB)" "$MAX_SIZE_KB"
    printf "  ${WHITE}[4]${RESET} %-22s → ${BOLD}%s${RESET}\n" "Copy to Clipboard" "$($COPY_CLIPBOARD && echo 'Yes' || echo 'No')"
    echo -e "  ─────────────────────────────────────────────────────"
    echo ""
    echo -e "  ${GREEN}[s]${RESET} Start Processing    ${YELLOW}[t]${RESET} Tree Only    ${RED}[q]${RESET} Quit"
    echo ""
}

tui_prompt() {
    local prompt_text="${1:-▸ }"
    echo -en "  ${CYAN}${prompt_text}${RESET}"
}

tui_run() {
    local choice
    while true; do
        tui_clear
        tui_banner
        tui_show_menu
        tui_prompt "Choice: "
        read -r choice

        case "$choice" in
            1)
                echo ""
                tui_prompt "Enter target directory [.]: "
                read -r -e input   # -e enables readline (tab completion)
                if [[ -n "$input" ]]; then
                    if [[ -d "$input" ]]; then
                        TARGET_DIR="$input"
                    else
                        error "Directory not found: $input"
                        read -rp "  Press Enter to continue..."
                    fi
                else
                    TARGET_DIR="."
                fi
                ;;
            2)
                echo ""
                tui_prompt "Enter output filename [flat_output.txt]: "
                read -r input
                [[ -n "$input" ]] && OUTPUT_FILE="$input"
                ;;
            3)
                echo ""
                tui_prompt "Enter max file size in KB [100]: "
                read -r input
                if [[ -n "$input" ]] && [[ "$input" =~ ^[0-9]+$ ]]; then
                    MAX_SIZE_KB="$input"
                elif [[ -n "$input" ]]; then
                    error "Invalid number: $input"
                    read -rp "  Press Enter to continue..."
                fi
                ;;
            4)
                COPY_CLIPBOARD=$( $COPY_CLIPBOARD && echo false || echo true )
                ;;
            s|S)
                echo ""
                TARGET_DIR="${TARGET_DIR:-.}"
                if [[ ! -d "$TARGET_DIR" ]]; then
                    error "Directory not found: $TARGET_DIR"
                    read -rp "  Press Enter to continue..."
                    continue
                fi
                generate_output "$TARGET_DIR" "$OUTPUT_FILE"
                echo ""
                echo -e "  ${DIM}Press Enter to return to menu...${RESET}"
                read -r
                ;;
            t|T)
                echo ""
                TARGET_DIR="${TARGET_DIR:-.}"
                if [[ ! -d "$TARGET_DIR" ]]; then
                    error "Directory not found: $TARGET_DIR"
                    read -rp "  Press Enter to continue..."
                    continue
                fi
                echo -e "${BOLD}Project Tree:${RESET}"
                echo ""
                generate_tree "$TARGET_DIR"
                echo ""
                echo -e "  ${DIM}Press Enter to return to menu...${RESET}"
                read -r
                ;;
            q|Q)
                echo ""
                info "Bye!"
                exit 0
                ;;
            *)
                warn "Unknown option: $choice"
                sleep 0.5
                ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════
#  Install
# ═══════════════════════════════════════════════════════════════════

do_install() {
    local script_source
    script_source="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

    echo ""
    info "Installing ${BOLD}${SCRIPT_NAME} v${VERSION}${RESET} ..."
    echo ""

    # Create directory
    mkdir -p "$INSTALL_DIR"
    success "Created ${INSTALL_DIR}/"

    # Copy script
    cp "$script_source" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod +x "$INSTALL_DIR/$SCRIPT_NAME"
    success "Copied to ${INSTALL_DIR}/${SCRIPT_NAME}"

    # Add to PATH in .bashrc
    local path_line='export PATH="$HOME/scripts:$PATH"'
    if grep -qF '$HOME/scripts' "$HOME/.bashrc" 2>/dev/null; then
        info "\$HOME/scripts already in ~/.bashrc PATH — skipping"
    else
        {
            echo ""
            echo "# >>> flat2llm PATH (added by --install) >>>"
            echo "$path_line"
            echo "# <<< flat2llm PATH <<<"
        } >> "$HOME/.bashrc"
        success "Added PATH entry to ~/.bashrc"
    fi

    # Also handle .zshrc if it exists
    if [[ -f "$HOME/.zshrc" ]]; then
        if grep -qF '$HOME/scripts' "$HOME/.zshrc" 2>/dev/null; then
            info "\$HOME/scripts already in ~/.zshrc PATH — skipping"
        else
            {
                echo ""
                echo "# >>> flat2llm PATH (added by --install) >>>"
                echo "$path_line"
                echo "# <<< flat2llm PATH <<<"
            } >> "$HOME/.zshrc"
            success "Added PATH entry to ~/.zshrc"
        fi
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}Installation complete!${RESET}"
    echo ""
    echo -e "  Next steps:"
    echo -e "    ${CYAN}source ~/.bashrc${RESET}   (or open a new terminal)"
    echo -e "    ${CYAN}${SCRIPT_NAME}${RESET}              (launch TUI)"
    echo -e "    ${CYAN}${SCRIPT_NAME} ./my-project${RESET} (quick flatten)"
    echo ""

    # ─── One-liner for .bashrc ─────────────────────────────────
    echo -e "  ${DIM}── One-liner to paste into .bashrc manually: ──${RESET}"
    echo -e "  ${YELLOW}export PATH=\"\$HOME/scripts:\$PATH\"${RESET}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════
#  CLI — Help & Argument Parsing
# ═══════════════════════════════════════════════════════════════════

show_help() {
    cat << EOF

  ${BOLD}${SCRIPT_NAME}${RESET} v${VERSION}  —  Flatten a codebase into a single text for LLMs

  ${BOLD}USAGE${RESET}
    ${SCRIPT_NAME}                       Launch interactive TUI
    ${SCRIPT_NAME} [OPTIONS] <DIRECTORY>  CLI mode

  ${BOLD}OPTIONS${RESET}
    -o, --output <FILE>     Output file        (default: flat_output.txt)
    -s, --max-size <KB>     Max file size in KB (default: 100)
    -c, --clipboard         Also copy output to clipboard
    -t, --tree-only         Only print the directory tree, no content
        --install           Install to ~/scripts and configure PATH
    -h, --help              Show this help
    -v, --version           Show version

  ${BOLD}EXAMPLES${RESET}
    ${SCRIPT_NAME}                           # TUI mode
    ${SCRIPT_NAME} ./my-project              # Flatten to flat_output.txt
    ${SCRIPT_NAME} -o out.txt -s 200 ./src   # Custom output, 200KB limit
    ${SCRIPT_NAME} -c ./project              # Flatten + copy to clipboard
    ${SCRIPT_NAME} -t ./project              # Tree structure only

  ${BOLD}INSTALL${RESET}
    bash ${SCRIPT_NAME} --install            # Copy to ~/scripts, add to PATH

EOF
}

# ═══════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════

main() {
    local positional_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help; exit 0 ;;
            -v|--version)
                echo "${SCRIPT_NAME} v${VERSION}"; exit 0 ;;
            --install)
                do_install; exit 0 ;;
            -o|--output)
                OUTPUT_FILE="${2:?Missing argument for $1}"; shift 2 ;;
            -s|--max-size)
                MAX_SIZE_KB="${2:?Missing argument for $1}"; shift 2 ;;
            -c|--clipboard)
                COPY_CLIPBOARD=true; shift ;;
            -t|--tree-only)
                TREE_ONLY=true; shift ;;
            --)
                shift; positional_args+=("$@"); break ;;
            -*)
                error "Unknown option: $1"
                echo "  Run '${SCRIPT_NAME} --help' for usage."
                exit 1 ;;
            *)
                positional_args+=("$1"); shift ;;
        esac
    done

    # If a positional argument is provided, use it as TARGET_DIR
    if [[ ${#positional_args[@]} -gt 0 ]]; then
        TARGET_DIR="${positional_args[0]}"

        if [[ ! -d "$TARGET_DIR" ]]; then
            error "Not a directory: $TARGET_DIR"
            exit 1
        fi

        if $TREE_ONLY; then
            generate_tree "$TARGET_DIR"
        else
            generate_output "$TARGET_DIR" "$OUTPUT_FILE"
        fi
    else
        # No directory given — launch TUI
        if [[ ! -t 0 ]]; then
            error "No directory specified and stdin is not a terminal."
            echo "  Run '${SCRIPT_NAME} --help' for usage."
            exit 1
        fi
        tui_run
    fi
}

main "$@"
