# Multi-stage build: compile a static binary, then ship it on distroless for a tiny, rootless
# runtime image.
#
# Fargate tasks here run on linux/amd64 (task cpu_architecture X86_64). We cross-compile to amd64
# explicitly so the image is correct regardless of the builder's architecture (e.g. an Apple Silicon
# / arm64 Mac) — otherwise the binary defaults to the host arch and the container fails at runtime
# with "exec /server: exec format error". Running the build stage natively (--platform=$BUILDPLATFORM)
# keeps it fast; Go does the cross-compile via GOARCH rather than emulation.
FROM --platform=$BUILDPLATFORM golang:1.23 AS build
ARG TARGETARCH=amd64
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH} go build -o /out/server .

FROM --platform=linux/amd64 gcr.io/distroless/static-debian12:nonroot
WORKDIR /
COPY --from=build /out/server /server
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/server"]
