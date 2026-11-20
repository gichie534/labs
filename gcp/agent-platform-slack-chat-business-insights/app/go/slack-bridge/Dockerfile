# One image for both Cloud Run services (MODE=ingress | worker).
FROM golang:1.26 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/slack-bridge .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/slack-bridge /slack-bridge
USER nonroot:nonroot
ENTRYPOINT ["/slack-bridge"]
