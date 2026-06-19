echo "NOTE: For a real run, change the docker image and the run script in docker-compose.yaml!"

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
export INPUT_ASSETS_DIR=/modeldata1/dig/datasets/pcb/assets
export OUTPUT_DIR=/modeldata1/dig/runs/pcb-${TIMESTAMP}
export COOKBOOKS_DIR=/home/azureuser/dev/physical-ai-data-factory/skills/physical-ai-defect-image-generation/assets/cookbooks
