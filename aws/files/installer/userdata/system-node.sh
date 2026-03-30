    #!/bin/bash
    set -ex
    
    # ── ECR credential helper ───────────────────────────────
    mkdir -p /opt/ecr-auth/bin /opt/ecr-auth/.docker
    dnf install -y amazon-ecr-credential-helper
    cp /usr/bin/docker-credential-ecr-login /opt/ecr-auth/bin/docker-credential-ecr-login
    chmod +x /opt/ecr-auth/bin/docker-credential-ecr-login
    echo '{"credsStore":"ecr-login"}' > /opt/ecr-auth/.docker/config.json
    
    # No autoscale needed for system nodes (ARM baseline)
