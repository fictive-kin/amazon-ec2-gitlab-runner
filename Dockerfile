FROM docker:29.9-cli

LABEL runner-executor=docker
LABEL description="A simple docker image for gitlab runner use"

# Alpine marks the system Python as externally managed (PEP 668), so the AWS CLI
# and boto3 are installed from apk packages rather than pip.
RUN set -x \
      && echo -e "\e[93m==> Adding runtime dependencies...\e[39m" \
      && apk add --no-cache --virtual .run-deps \
              alpine-sdk \
              make \
              zip \
              bash \
              jq \
              python3 \
              py3-pip \
              py3-boto3 \
              groff \
              aws-cli
