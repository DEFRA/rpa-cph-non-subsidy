FROM mcr.microsoft.com/dotnet/sdk:10.0.403-noble AS build
WORKDIR /src
COPY RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain.csproj \
    RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/
COPY RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/RPA.CPH.NonSubsidy.Web.csproj \
    RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/

ARG NUGET_SOURCE
RUN if [ -n "$NUGET_SOURCE" ]; then \
        dotnet restore RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/RPA.CPH.NonSubsidy.Web.csproj --source "$NUGET_SOURCE"; \
    else \
        dotnet restore RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/RPA.CPH.NonSubsidy.Web.csproj; \
    fi

COPY RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/ \
    RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Domain/
COPY RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/ \
    RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/
RUN dotnet publish RPA.CPH.NonSubsidy.Domain/RPA.CPH.NonSubsidy.Web/RPA.CPH.NonSubsidy.Web.csproj \
-c Release --no-restore -o /out /p:UseAppHost=false

# Ubuntu includes ICU: en-GB dates/validation must not use invariant globalization.
FROM mcr.microsoft.com/dotnet/aspnet:10.0.14-noble AS final
WORKDIR /app
COPY --from=build /out/ ./
ENV ASPNETCORE_HTTP_PORTS=8080 \
    ASPNETCORE_ENVIRONMENT=Production \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=false
EXPOSE 8080
USER $APP_UID
ENTRYPOINT ["dotnet", "RPA.CPH.NonSubsidy.Web.dll"]
