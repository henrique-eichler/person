FROM eclipse-temurin:21-jre-alpine AS runtime
WORKDIR /app

# Create non-root user
RUN addgroup -S app && adduser -S app -G app

# Copy boot jar from build stage
COPY ./build/libs/app.jar /app/app.jar

EXPOSE 8080
USER app
ENTRYPOINT ["java","-jar","/app/app.jar"]