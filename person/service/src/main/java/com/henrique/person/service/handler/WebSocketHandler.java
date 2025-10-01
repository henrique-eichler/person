package com.henrique.person.service.handler;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import java.io.IOException;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

@Component
public class WebSocketHandler extends TextWebSocketHandler {

    private final ObjectMapper objectMapper;

    private final Map<String, WebSocketSession> sessions = new ConcurrentHashMap<>();
    private final Map<String, AbstractServiceHandler<?>> services = new ConcurrentHashMap<>();

    public WebSocketHandler(ObjectMapper objectMapper) {
        this.objectMapper = objectMapper;
    }

    public void register(String topic, AbstractServiceHandler<?> abstractServiceHandler) {
        services.put(topic, abstractServiceHandler);
    }

    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        // Store the session with the client UUID as the key
        String clientUuid = getClientUuid(session);
        sessions.put(clientUuid, session);
    }

    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) throws Exception {
        String payload = message.getPayload();
        JsonNode jsonNode = objectMapper.readTree(payload);

        // Extract destination and body from the message
        String destination = jsonNode.get("destination").asText();
        AbstractServiceHandler<?> abstractServiceHandler = services.get(destination);
        if (abstractServiceHandler != null) {
            Class<?> clazz = abstractServiceHandler.getType();
            Object object = jsonNode.has("body") ? objectMapper.readValue(jsonNode.get("body").asText(), clazz) : null;
            processGeneric(abstractServiceHandler, session, object);
        }

        session.getAttributes().put("updatedAt", new SimpleDateFormat("dd/MM/yyyy HH:mm:ss").format(new Date()));
    }

    @SuppressWarnings("unchecked")
    private <T> void processGeneric(AbstractServiceHandler<T> handler, WebSocketSession session, Object obj) throws IOException {
        handler.process(session, (T) obj);
    }

    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
        session.getAttributes().put("disconectedAt", new SimpleDateFormat("dd/MM/yyyy HH:mm:ss").format(new Date()));
    }

    public String getClientUuid(WebSocketSession session) {
        return (String) session.getAttributes().getOrDefault("clientUuid", session.getId());
    }

    public void sendToSession(WebSocketSession session, String destination, Object data) {
        // Create a message with destination and body
        Map<String, Object> message = Map.of(
                "destination", destination,
                "body", data
        );

        // Convert to JSON and send
        try {
            String jsonMessage = objectMapper.writeValueAsString(message);
            session.sendMessage(new TextMessage(jsonMessage));
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    public void sendToClientId(String clientId, String destination, Object data) {
        sendToSession(sessions.get(clientId), destination, data);
    }
}
