# Multi-stage build: compile a static binary, then ship it on distroless for a tiny, rootless
# runtime image suitable for GKE Autopilot (hardened workload posture).
#
# GKE nodes are linux/amd64. We cross-compile to amd64 explicitly so the image is correct regardless
# of the builder's architecture (e.g. an Apple Silicon / arm64 Mac). The build stage runs natively
# on the builder (--platform=$BUILDPLATFORM) and Go cross-compiles via GOARCH rather than emulation.
FROM --platform=$BUILDPLATFORM golang:1.24 AS build
ARG TARGETARCH=amd64
WORKDIR /src
COPY go.mod go.sum* ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -o /out/app .

FROM --platform=linux/amd64 gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
