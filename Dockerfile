# syntax=docker/dockerfile:1
# Builds rpa-cph-non-subsidy per Defra .NET container standards (github.com/DEFRA/defra-docker-dotnetcore).
ARG PARENT_VERSION=2.1.9-dotnet10.0

# Development stage: SDK-based parent image used to restore, test and publish the app.
FROM defradigital/dotnetcore-development:$PARENT_VERSION AS development
ENV TZ="Europe/London"
ARG PARENT_VERSION

# Label the development image with the parent image it extends.
LABEL uk.gov.defra.parent-image=defradigital/dotnetcore-development:${PARENT_VERSION}

# Create directories for app, its Domain dependency, and test files to be copied into.
RUN mkdir -p ./RPA.CPH.NonSubsidy.Domain/ ./RPA.CPH.NonSubsidy.Web/ ./RPA.CPH.NonSubsidy.Web.Tests/

# Install test dependencies.
COPY --chown=dotnet:dotnet RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web.Tests/*.csproj ./RPA.CPH.NonSubsidy.Web.Tests/
RUN dotnet restore ./RPA.CPH.NonSubsidy.Web.Tests/RPA.CPH.NonSubsidy.Web.Tests.csproj

# Install app dependencies (Web references Domain as a project reference).
# NUGET_SOURCE is an optional non-secret package source (e.g. an internal feed mirror).
ARG NUGET_SOURCE
COPY --chown=dotnet:dotnet RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/*.csproj ./RPA.CPH.NonSubsidy.Domain/
COPY --chown=dotnet:dotnet RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/*.csproj ./RPA.CPH.NonSubsidy.Web/
RUN if [ -n "$NUGET_SOURCE" ]; then \
        dotnet restore ./RPA.CPH.NonSubsidy.Web/RPA.CPH.NonSubsidy.Web.csproj --source "$NUGET_SOURCE"; \
    else \
        dotnet restore ./RPA.CPH.NonSubsidy.Web/RPA.CPH.NonSubsidy.Web.csproj; \
    fi

# Copy in test and app code.
COPY --chown=dotnet:dotnet RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web.Tests/ ./RPA.CPH.NonSubsidy.Web.Tests/
COPY --chown=dotnet:dotnet RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/ ./RPA.CPH.NonSubsidy.Domain/
COPY --chown=dotnet:dotnet RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/ ./RPA.CPH.NonSubsidy.Web/

# Build the app.
RUN dotnet publish ./RPA.CPH.NonSubsidy.Web/ -c Release -o /home/dotnet/out

# Expose the app on a defined port, configurable via a build argument.
ARG PORT=8080
ENV PORT=${PORT}
EXPOSE ${PORT}

# Exec form needs a script to interpolate ${PORT}; the script itself execs dotnet so it still
#   receives signals directly rather than a shell.
# Root-owned so the dotnet user can't modify its own startup script; switch back afterwards.
USER root
COPY --chown=root:root dev-entrypoint.sh ./
RUN chmod +x ./dev-entrypoint.sh
USER dotnet
CMD ["./dev-entrypoint.sh"]

# Production stage
FROM defradigital/dotnetcore:$PARENT_VERSION AS production
ARG PARENT_VERSION
ARG BUILD_VERSION=local
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown

# Label the production image with the parent image it extends.
LABEL uk.gov.defra.parent-image=defradigital/dotnetcore-development:${PARENT_VERSION} \
      org.opencontainers.image.title="rpa-cph-non-subsidy" \
      org.opencontainers.image.version="$BUILD_VERSION" \
      org.opencontainers.image.revision="$VCS_REF" \
      org.opencontainers.image.created="$BUILD_DATE"

# Expose the app on a defined port, configurable via a build argument.
ARG PORT=8080
# Globalization (not invariant) is required for en-GB date/validation formatting.
ENV ASPNETCORE_URLS=http://*:${PORT} \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false
EXPOSE ${PORT}

# Switch to root temporarily to lock down file permissions.
USER root

# Copy the compiled app from the development build stage, assigning root ownership to
#   prevent modification by other users.
COPY --from=development --chown=root:root /home/dotnet/out/ ./

# Remove write permissions, then drop back to the unprivileged user.
RUN chmod -R a-w /home/dotnet
USER dotnet

# Set the default command for production to run the compiled app.
CMD ["dotnet", "RPA.CPH.NonSubsidy.Web.dll"]

