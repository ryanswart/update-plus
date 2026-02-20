#!/usr/bin/env bash
# Update Plus - Restore functions
# Version: 4.0.1
# For OpenClaw

# Restore from backup
restore_backup() {
  local backup_id="$1"
  local restore_label="${2:-}"
  local force_restore="${3:-}"

  # Handle --force as second argument
  if [[ "$restore_label" == "--force" ]]; then
    force_restore="--force"
    restore_label=""
  fi

  if [[ -z "$backup_id" ]]; then
    log_error "Please specify a backup ID"
    list_backups
    return 1
  fi

  local backup_path="${BACKUP_DIR}/${backup_id}"
  local tmp_extract_dir=$(mktemp -d)
  local decrypted_path=""
  local should_cleanup_decrypted=false

  if [[ ! -f "$backup_path" ]]; then
    log_error "Backup not found: $backup_path"
    list_backups
    return 1
  fi

  # Decrypt if needed
  if [[ "${backup_path##*.}" == "gpg" ]]; then
    if ! decrypt_backup "$backup_path" decrypted_path; then
      rm -rf "$tmp_extract_dir"
      return 1
    fi
    backup_path="$decrypted_path"
    should_cleanup_decrypted=true
  fi

  # Extract to temp directory
  log_info "Extracting backup..."
  if ! tar -xzf "$backup_path" -C "$tmp_extract_dir" 2>/dev/null; then
    log_error "Failed to extract backup."
    cleanup_restore "$tmp_extract_dir" "$decrypted_path" "$should_cleanup_decrypted"
    return 1
  fi

  # Sanitize paths in extracted backup BEFORE processing
  sanitize_backup_paths "$tmp_extract_dir"

  # Detect backup structure
  local labels_found=()
  for dir in "$tmp_extract_dir"/*/; do
    if [[ -d "$dir" ]]; then
      labels_found+=("$(basename "$dir")")
    fi
  done

  # Restore based on format
  if [[ ${#labels_found[@]} -eq 0 ]]; then
    restore_legacy_backup "$tmp_extract_dir" "$force_restore"
  else
    restore_labeled_backup "$tmp_extract_dir" "$restore_label" "$force_restore" "${labels_found[@]}"
  fi

  local result=$?

  # Cleanup
  cleanup_restore "$tmp_extract_dir" "$decrypted_path" "$should_cleanup_decrypted"

  if [[ $result -eq 0 ]]; then
    log_success "Restore completed from: $backup_id"
  fi

  return $result
}

# Decrypt backup file
decrypt_backup() {
  local backup_path="$1"
  local -n output_path=$2

  if ! command_exists gpg; then
    log_error "gpg command not found, cannot decrypt."
    return 1
  fi

  log_info "Decrypting backup..."
  output_path=$(mktemp)

  if ! gpg --decrypt --output "$output_path" "$backup_path" 2>/dev/null; then
    log_error "Failed to decrypt backup."
    rm -f "$output_path"
    return 1
  fi

  return 0
}

# Restore legacy backup (flat structure)
restore_legacy_backup() {
  local tmp_dir="$1"
  local force_restore="$2"

  log_info "Detected legacy backup format"

  # Get default skills dir
  local skills_dir=$(echo "$SKILLS_DIRS_JSON" | jq -r '.[0].path // "~/.clawdbot/skills"')
  skills_dir=$(expand_path "$skills_dir")

  if [[ "$force_restore" != "--force" ]]; then
    log_warning "This will restore to: ${skills_dir}"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Restore cancelled"
      return 0
    fi
  fi

  log_info "Restoring to $skills_dir"
  rsync -a "$tmp_dir/" "$skills_dir/" 2>/dev/null
  log_success "Restored legacy backup"
  return 0
}

# Restore labeled backup (new format)
restore_labeled_backup() {
  local tmp_dir="$1"
  local restore_label="$2"
  local force_restore="$3"
  shift 3
  local labels_found=("$@")

  log_info "Detected backup labels: ${labels_found[*]}"

  # Build restore mapping
  declare -A restore_map
  restore_map=()

  # From backup_paths config
  local backup_paths_json=$(get_backup_paths)
  if [[ -n "$backup_paths_json" ]] && [[ "$backup_paths_json" != "null" ]]; then
    while IFS= read -r path_config; do
      local label=$(echo "$path_config" | jq -r '.label')
      local path=$(echo "$path_config" | jq -r '.path')
      path=$(expand_path "$path")
      restore_map["$label"]="$path"
    done < <(echo "$backup_paths_json" | jq -c '.[]')
  fi

  # Default mappings for common labels
  [[ -v 'restore_map[config]' ]] || restore_map["config"]="${HOME}/.openclaw"
  [[ -v 'restore_map[workspace]' ]] || restore_map["workspace"]="${HOME}/.openclaw/workspace"
  [[ -v 'restore_map[skills]' ]] || restore_map["skills"]="${HOME}/.openclaw/skills"
  [[ -v 'restore_map[extensions]' ]] || restore_map["extensions"]="${HOME}/.openclaw/extensions"
  [[ -v 'restore_map[prod]' ]] || restore_map["prod"]="${HOME}/.openclaw/skills"
  [[ -v 'restore_map[dev]' ]] || restore_map["dev"]="${HOME}/.openclaw/skills-dev"
  [[ -v 'restore_map[default]' ]] || restore_map["default"]="${HOME}/.openclaw/skills"

  # Show restore plan
  echo ""
  log_info "Restore plan:"
  for label in "${labels_found[@]}"; do
    local target="${restore_map[$label]:-unknown}"
    if [[ -n "$restore_label" ]] && [[ "$label" != "$restore_label" ]]; then
      echo "  ○ $label → $target (skipped)"
    else
      echo "  → $label → $target"
    fi
  done
  echo ""

  # Confirm
  if [[ "$force_restore" != "--force" ]]; then
    log_warning "This will overwrite the above directories!"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      log_info "Restore cancelled"
      return 0
    fi
  fi

  # Execute restore
  local restored_count=0
  for label in "${labels_found[@]}"; do
    # Skip if specific label requested
    if [[ -n "$restore_label" ]] && [[ "$label" != "$restore_label" ]]; then
      continue
    fi

    local target="${restore_map[$label]:-}"
    if [[ -z "$target" ]] || [[ "$target" == "unknown" ]]; then
      log_warning "Unknown label '$label', skipping"
      continue
    fi

    log_info "Restoring $label → $target"

    # Ensure target parent exists
    mkdir -p "$(dirname "$target")"

    # Restore with rsync
    if rsync -a --delete "$tmp_dir/$label/" "$target/" 2>/dev/null; then
      log_success "Restored $label"
      
      # Fix hardcoded paths in all config files (e.g., /root/.openclaw -> /home/runner)
      if command -v find >/dev/null 2>&1 && command -v sed >/dev/null 2>&1; then
        local original_home=""
        # Try to detect original home from common patterns in the backup
        # Check for /root first (common in Docker containers) - use -q to avoid broken pipe
        if grep -rIq "/root/" "$target/" 2>/dev/null; then
          original_home="/root"
          log_info "Detected original home: /root"
        fi
        
        # Check for any /home/*/ paths (various usernames)
        # Use temp file to avoid broken pipe from sort | uniq | head pipeline
        local detected_home=""
        local detect_temp
        detect_temp=$(mktemp)
        if grep -rohI "/home/[^/]*/" "$target/" 2>/dev/null | grep -v ".git/" > "$detect_temp" 2>/dev/null; then
          detected_home=$(sort < "$detect_temp" | uniq -c | sort -rn | head -1 | awk '{print $2}' | sed 's|/$||' || true)
        fi
        rm -f "$detect_temp"
        
        if [[ -n "$detected_home" ]]; then
          original_home="$detected_home"
          log_info "Detected original home from backup: $original_home"
        fi
        
        # Also check for home references without leading slash (e.g., home/exedev/)
        local detected_home_rel=""
        detect_temp=$(mktemp)
        if grep -rohI "home/[^/]*/" "$target/" 2>/dev/null | grep -v ".git/" > "$detect_temp" 2>/dev/null; then
          detected_home_rel=$(sort < "$detect_temp" | uniq -c | sort -rn | head -1 | awk '{print $2}' | sed 's|/$||' || true)
        fi
        rm -f "$detect_temp"
        if [[ -n "$detected_home_rel" ]]; then
          # Only use if we didn't already find an absolute path
          if [[ -z "$original_home" ]]; then
            original_home="/$detected_home_rel"
            log_info "Detected relative home path from backup: $original_home"
          fi
        fi
        
        if [[ -n "$original_home" ]] && [[ "$original_home" != "$HOME" ]]; then
          log_info "Fixing hardcoded paths: $original_home → $HOME"
          
          # Create a temp file for tracking what was changed
          local changes_made=0
          
          # Use ripgrep to find files with the path (much faster than find+grep)
          local files_with_path
          files_with_path=$(rg -l --type-add 'backup:*.{tar.gz,tgz,gz,zip,rar,7z,gpg,png,jpg,jpeg,gif,bmp,ico,webp,woff,woff2,ttf,otf,eot,mp3,mp4,avi,mov,webm,pdf,exe,dll,so,dylib}' -Tbackup "$original_home" "$target" 2>/dev/null || true)
          
          if [[ -n "$files_with_path" ]]; then
            # Process each file
            while IFS= read -r file; do
              [[ -z "$file" ]] && continue
              [[ -d "$file" ]] && continue
              
              # Handle JSON files with jq for proper structure handling
              if [[ "$file" == *.json ]] && command -v jq >/dev/null 2>&1; then
                local temp_json
                temp_json=$(mktemp)
                if jq --arg old "$original_home" --arg new "$HOME" 'walk(if type == "string" then gsub($old; $new) else . end)' "$file" > "$temp_json" 2>/dev/null; then
                  mv "$temp_json" "$file" && changes_made=$((changes_made + 1))
                else
                  rm -f "$temp_json"
                  perl -i -pe "s|\Q$original_home\E|$HOME|g" "$file" 2>/dev/null && changes_made=$((changes_made + 1))
                fi
              else
                # Use perl for fast in-place replacement
                if perl -i -pe "s|\Q$original_home\E|$HOME|g" "$file" 2>/dev/null; then
                  changes_made=$((changes_made + 1))
                fi
              fi
            done <<< "$files_with_path"
          fi
          
          log_info "Path replacement complete. Modified $changes_made files."
          
          # Validate: check if any hardcoded paths remain using ripgrep
          local remaining_count
          remaining_count=$(rg -c "$original_home" "$target" 2>/dev/null | awk -F: '{sum+=$2} END {print sum+0}' || echo "0")
          
          if [[ "$remaining_count" -gt 0 ]]; then
            log_warning "$remaining_count occurrences of $original_home may still remain in restored files"
            # Show sample of remaining paths (first 3)
            rg "$original_home" "$target" 2>/dev/null | head -3 && true
          else
            log_success "All hardcoded paths successfully replaced"
          fi
        fi
      fi
          if [[ "$remaining_count" -gt 0 ]]; then
            log_warning "$remaining_count occurrences of $original_home may still remain in restored files"
            # Show sample of remaining paths (first 3)
            grep -r "$original_home" "$target/" 2>/dev/null | grep -v ".git/" | head -3 >&2 || true
          else
            log_success "All hardcoded paths successfully replaced"
          fi
        fi
      fi
      
      restored_count=$((restored_count + 1))
    else
      log_error "Failed to restore $label"
    fi
  done

  if [[ $restored_count -eq 0 ]]; then
    log_error "No labels were restored"
    return 1
  fi

  return 0
}

# Sanitize hardcoded paths in extracted backup BEFORE restore
# This runs on the temp directory before any files are moved to their final locations
sanitize_backup_paths() {
  local tmp_dir="$1"
  
  log_info "Sanitizing backup paths..."
  
  # Detect common home directory patterns in the backup
  local original_home=""
  local detected_paths=()
  
  # Check for /root (common in Docker containers)
  # Use grep -q to avoid broken pipe errors from head
  if grep -rIq "/root/" "$tmp_dir/" 2>/dev/null; then
    detected_paths+=("/root")
    log_info "Detected /root paths in backup"
  fi
  
  # Check for /home/* patterns - get all unique home directories
  # Use a temp file to avoid broken pipe issues
  local home_paths=""
  local grep_temp
  grep_temp=$(mktemp)
  if grep -rohI "/home/[^/]*/" "$tmp_dir/" 2>/dev/null | grep -v ".git/" > "$grep_temp" 2>/dev/null; then
    home_paths=$(sort -u < "$grep_temp" | sed 's|/$||' || true)
  fi
  rm -f "$grep_temp"
  if [[ -n "$home_paths" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && detected_paths+=("$path")
    done <<< "$home_paths"
  fi
  
  # Also check for patterns like "home/username" without leading slash
  local rel_paths=""
  grep_temp=$(mktemp)
  if grep -rohI "home/[^/]*/" "$tmp_dir/" 2>/dev/null | grep -v ".git/" > "$grep_temp" 2>/dev/null; then
    rel_paths=$(sort -u < "$grep_temp" | sed 's|/$||' || true)
  fi
  rm -f "$grep_temp"
  if [[ -n "$rel_paths" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && detected_paths+=("/$path")
    done <<< "$rel_paths"
  fi
  
  # Remove duplicates and current HOME from the list
  local unique_paths=()
  for path in "${detected_paths[@]}"; do
    # Skip if it's the current HOME
    [[ "$path" == "$HOME" ]] && continue
    # Skip if already in unique_paths
    local found=0
    for existing in "${unique_paths[@]}"; do
      [[ "$existing" == "$path" ]] && { found=1; break; }
    done
    [[ $found -eq 0 ]] && unique_paths+=("$path")
  done
  
  if [[ ${#unique_paths[@]} -eq 0 ]]; then
    log_info "No hardcoded home paths detected in backup"
    return 0
  fi
  
  log_info "Detected ${#unique_paths[@]} hardcoded home path(s) to sanitize: ${unique_paths[*]}"
  
  # Replace all detected paths with current HOME using fast tools
  local total_changes=0
  for original_home in "${unique_paths[@]}"; do
    log_info "Replacing: $original_home → $HOME"
    
    # Use ripgrep to find files with the path (much faster than find+grep)
    # Then use perl for in-place replacement (faster than sed, handles binary check)
    local files_with_path
    files_with_path=$(rg -l --type-add 'backup:*.{tar.gz,tgz,gz,zip,rar,7z,gpg,png,jpg,jpeg,gif,bmp,ico,webp,woff,woff2,ttf,otf,eot,mp3,mp4,avi,mov,webm,pdf,exe,dll,so,dylib}' -Tbackup "$original_home" "$tmp_dir" 2>/dev/null || true)
    
    if [[ -z "$files_with_path" ]]; then
      continue
    fi
    
    # Process each file
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue
      [[ -d "$file" ]] && continue
      
      # Handle JSON files with jq for proper structure handling
      if [[ "$file" == *.json ]] && command -v jq >/dev/null 2>&1; then
        local temp_json
        temp_json=$(mktemp)
        if jq --arg old "$original_home" --arg new "$HOME" 'walk(if type == "string" then gsub($old; $new) else . end)' "$file" > "$temp_json" 2>/dev/null; then
          mv "$temp_json" "$file"
          total_changes=$((total_changes + 1))
        else
          rm -f "$temp_json"
          # Fall back to perl
          perl -i -pe "s|\Q$original_home\E|$HOME|g" "$file" 2>/dev/null && total_changes=$((total_changes + 1))
        fi
      else
        # Use perl for fast in-place replacement on all other files
        # Perl handles binary files better than sed
        if perl -i -pe "s|\Q$original_home\E|$HOME|g" "$file" 2>/dev/null; then
          total_changes=$((total_changes + 1))
        fi
      fi
    done <<< "$files_with_path"
  done
  
  log_info "Sanitized $total_changes files"
  
  # Final validation - check if any hardcoded paths remain
  local remaining=0
  for path in "${unique_paths[@]}"; do
    local count=0
    local grep_output
    grep_output=$(grep -r "$path" "$tmp_dir/" 2>/dev/null | grep -v ".git/" || true)
    if [[ -n "$grep_output" ]]; then
      count=$(echo "$grep_output" | wc -l | tr -d ' ')
    fi
    remaining=$((remaining + count))
  done
  
  if [[ $remaining -gt 0 ]]; then
    log_warning "$remaining hardcoded path references may still remain"
  else
    log_success "Backup paths sanitized successfully"
  fi
}

# Cleanup restore temp files
cleanup_restore() {
  local tmp_dir="$1"
  local decrypted_path="$2"
  local should_cleanup="$3"

  rm -rf "$tmp_dir"
  if [[ "$should_cleanup" == true ]] && [[ -n "$decrypted_path" ]]; then
    rm -f "$decrypted_path"
  fi
}

# Compare two backups
diff_backups() {
  local backup1="$1"
  local backup2="$2"

  if [[ -z "$backup1" ]] || [[ -z "$backup2" ]]; then
    log_error "Please provide two backup IDs to compare."
    list_backups
    return 1
  fi

  local backup1_path="${BACKUP_DIR}/${backup1}"
  local backup2_path="${BACKUP_DIR}/${backup2}"

  if [[ ! -f "$backup1_path" ]]; then
    log_error "Backup not found: $backup1_path"
    return 1
  fi
  if [[ ! -f "$backup2_path" ]]; then
    log_error "Backup not found: $backup2_path"
    return 1
  fi

  local tmp_dir1=$(mktemp -d)
  local tmp_dir2=$(mktemp -d)

  log_info "Extracting backups for comparison..."

  if ! tar -xzf "$backup1_path" -C "$tmp_dir1" 2>/dev/null; then
    log_error "Failed to extract $backup1"
    rm -rf "$tmp_dir1" "$tmp_dir2"
    return 1
  fi

  if ! tar -xzf "$backup2_path" -C "$tmp_dir2" 2>/dev/null; then
    log_error "Failed to extract $backup2"
    rm -rf "$tmp_dir1" "$tmp_dir2"
    return 1
  fi

  log_info "Comparing backups..."
  diff -r -u "$tmp_dir1" "$tmp_dir2" || true

  rm -rf "$tmp_dir1" "$tmp_dir2"
  log_info "Comparison complete."
  return 0
}
