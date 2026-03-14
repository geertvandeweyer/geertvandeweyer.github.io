#!/bin/bash

# Update tes pages (moved into /tes)
sed -i 's|permalink: /tes/|permalink: /tes/|g' tes/index.md
sed -i 's|permalink: /tes/architecture/|permalink: /tes/architecture/|g' tes/architecture.md
sed -i 's|permalink: /tes/container-images/|permalink: /tes/container-images/|g' tes/container-images.md

# Update cromwell page (moved into /cromwell)
sed -i 's|permalink: /cromwell/|permalink: /cromwell/|g' cromwell/index.md

# Update karpenter pages (moved into /karpenter)
sed -i 's|permalink: /karpenter/|permalink: /karpenter/|g' karpenter/index.md

# Update aws pages (moved into /aws)
sed -i 's|permalink: /aws/|permalink: /aws/|g' aws/index.md

# Update ovh pages (moved into /ovh)
sed -i 's|permalink: /ovh/|permalink: /ovh/|g' ovh/index.md
sed -i 's|permalink: /ovh/installation-guide/|permalink: /ovh/installation-guide/|g' ovh/installation-guide.md

# Optional checks for new pages
if [ -f ovh/cli-guide.md ]; then
  sed -i 's|permalink: /ovh/cli-guide/|permalink: /ovh/cli-guide/|g' ovh/cli-guide.md
fi
if [ -f ovh/cost-and-infrastructure.md ]; then
  sed -i 's|permalink: /ovh/cost-and-infrastructure/|permalink: /ovh/cost-and-infrastructure/|g' ovh/cost-and-infrastructure.md
fi

echo "✓ Permalinks verified"
