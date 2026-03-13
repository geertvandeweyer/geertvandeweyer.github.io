#!/bin/bash

# Update tes-index.md
sed -i 's|permalink: /tes/|permalink: /tes/|g' tes-index.md

# Update tes-architecture.md  
sed -i 's|permalink: /tes/architecture/|permalink: /tes/architecture/|g' tes-architecture.md

# Update tes-container-images.md
sed -i 's|permalink: /tes/container-images/|permalink: /tes/container-images/|g' tes-container-images.md

# Update cromwell-index.md
sed -i 's|permalink: /cromwell/|permalink: /cromwell/|g' cromwell-index.md

# Update karpenter-index.md
sed -i 's|permalink: /karpenter/|permalink: /karpenter/|g' karpenter-index.md

# Update aws-index.md
sed -i 's|permalink: /aws/|permalink: /aws/|g' aws-index.md

# Update ovh-index.md
sed -i 's|permalink: /ovh/|permalink: /ovh/|g' ovh-index.md

# Update ovh-installation-guide.md
sed -i 's|permalink: /ovh/installation-guide/|permalink: /ovh/installation-guide/|g' ovh-installation-guide.md

echo "✓ Permalinks verified"
