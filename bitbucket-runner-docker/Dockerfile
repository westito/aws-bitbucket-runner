FROM amazon/aws-cli:latest

ARG RUNNER_VERSION
ENV RUNNER_VERSION=${RUNNER_VERSION}
ENV RUNNER_TYPE=docker

COPY shared/start-runner.sh /usr/local/bin/start-runner
RUN chmod +x /usr/local/bin/start-runner
