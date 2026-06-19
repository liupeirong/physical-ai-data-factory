echo "NOTE: For a real run, change 3 things in docker-compose.yaml!"
echo "1. the docker image"
echo "2. mount run_org.sh instead of run.sh"
echo "3. uncomment the gpu section at the end"

read -r -p "Run TIMESTAMP to use (e.g. 20260619_120000): " TIMESTAMP
[ -n "$TIMESTAMP" ] || { echo "ERROR: TIMESTAMP is required"; return 1 2>/dev/null || exit 1; }
export TIMESTAMP
export INPUT_ASSETS_DIR=/datadrive/dig/datasets/pcb/assets
export OUTPUT_DIR=/datadrive/dig/runs/pcb-${TIMESTAMP}
export COOKBOOKS_DIR=/home/azureuser/dev/physical-ai-data-factory/skills/physical-ai-defect-image-generation/assets/cookbooks
