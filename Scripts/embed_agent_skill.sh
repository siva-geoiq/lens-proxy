#!/bin/bash

set -euo pipefail

SOURCE="${SRCROOT}/Skills/lens-operator"
DESTINATION="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/AgentSkills/lens-operator"

if [[ ! -f "${SOURCE}/SKILL.md" ]]; then
  echo "error: Lens operator skill is missing at ${SOURCE}" >&2
  exit 1
fi

/bin/mkdir -p "${DESTINATION}/agents" "${DESTINATION}/scripts" "${DESTINATION}/references"
/bin/cp "${SOURCE}/SKILL.md" "${DESTINATION}/SKILL.md"
/bin/cp "${SOURCE}/agents/openai.yaml" "${DESTINATION}/agents/openai.yaml"
/bin/cp "${SOURCE}/scripts/lensctl" "${DESTINATION}/scripts/lensctl"
/bin/cp "${SOURCE}/references/api.md" "${DESTINATION}/references/api.md"
/bin/cp "${SOURCE}/references/workflows.md" "${DESTINATION}/references/workflows.md"
/bin/chmod 755 "${DESTINATION}/scripts/lensctl"
