# ============================================================
# Script 16 — Master Reusable Auth Header
# WizEmp · Power BI Admin PowerShell Field Guide
# wizemp.com · github.com/wizemp/pbi-governance-scripts
# ============================================================

function Invoke-PBIWithCheckpoint {
    <#
    .SYNOPSIS
        Runs a scriptblock against a list of items, saving progress to a checkpoint
        file after each item. On restart, skips already-processed items.
    .PARAMETER Items
        Array of objects to process (workspaces, datasets, etc.)
    .PARAMETER IdProperty
        Name of the property that uniquely identifies each item. Default: "Id"
    .PARAMETER CheckpointFile
        Path to the JSON checkpoint file. Created automatically.
    .PARAMETER ScriptBlock
        The code to run for each item. Receives the item as $_ and must return
        a PSCustomObject (or $null to skip).
    .PARAMETER ResultsFile
        Path to the accumulated CSV results file.
    .EXAMPLE
        $datasets | Invoke-PBIWithCheckpoint `
            -CheckpointFile "C:\PBIAdmin\checkpoints\ds-refresh-check.json" `
            -ResultsFile    "C:\PBIAdmin\exports\refresh-status.csv" `
            -ScriptBlock {
                param($ds)
                # ... process $ds, return PSCustomObject
            }
    #>
    param(
        [object[]]$Items,
        [string]$IdProperty      = "Id",
        [string]$CheckpointFile,
        [string]$ResultsFile,
        [scriptblock]$ScriptBlock
    )

    # Load existing checkpoint (list of already-processed IDs)
    $processed = @{}
    if (Test-Path $CheckpointFile) {
        $checkpointData = Get-Content $CheckpointFile -Raw | ConvertFrom-Json
        foreach ($id in $checkpointData.ProcessedIds) { $processed[$id] = $true }
        Write-Host "Resuming: $($processed.Count) items already processed" -ForegroundColor Yellow
    }

    $totalItems    = $Items.Count
    $skipped       = 0
    $newlyDone     = 0
    $errors        = 0
    $resultsBuffer = [System.Collections.Generic.List[object]]::new()

    foreach ($item in $Items) {
        $itemId = $item.$IdProperty

        if ($processed[$itemId]) {
            $skipped++
            continue   # Already done in a previous run — skip
        }

        try {
            $result = & $ScriptBlock $item   # Execute the processing block

            if ($result) {
                $resultsBuffer.Add($result)
                # Flush buffer to CSV every 50 items (avoids memory bloat)
                if ($resultsBuffer.Count -ge 50) {
                    $resultsBuffer | Export-Csv $ResultsFile -NoTypeInformation -Encoding UTF8BOM -Append
                    $resultsBuffer.Clear()
                }
            }

            $processed[$itemId] = $true
            $newlyDone++

            # Save checkpoint after every item (survives crash at any point)
            @{ ProcessedIds = @($processed.Keys) } |
                ConvertTo-Json -Compress |
                Set-Content $CheckpointFile

        } catch {
            Write-Warning "Error processing item $itemId : $_"
            $errors++
        }

        # Progress
        $total_done = $skipped + $newlyDone
        Write-Progress -Activity "Processing items" `
            -Status "$total_done / $totalItems (skipped: $skipped, errors: $errors)" `
            -PercentComplete (($total_done / $totalItems) * 100)
    }

    # Flush remaining buffer
    if ($resultsBuffer.Count -gt 0) {
        $resultsBuffer | Export-Csv $ResultsFile -NoTypeInformation -Encoding UTF8BOM -Append
    }

    # Remove checkpoint on successful completion (clean slate for next run)
    if ($errors -eq 0 -and (Test-Path $CheckpointFile)) {
        Remove-Item $CheckpointFile -Force
        Write-Host "Checkpoint cleared (run completed successfully)" -ForegroundColor Green
    } else {
        Write-Warning "Checkpoint retained — $errors error(s) encountered. Re-run to retry failed items."
    }

    Write-Host "Processed: $newlyDone new | Skipped: $skipped | Errors: $errors"
}
