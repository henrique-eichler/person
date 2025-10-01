package com.henrique.person.service.config;

import com.henrique.person.service.handler.WebSocketHandler;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;
import org.springframework.web.socket.server.HandshakeInterceptor;
import org.springframework.web.socket.server.standard.ServletServerContainerFactoryBean;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Map;

@Configuration
@EnableWebSocket
public class WebSocketConfig implements WebSocketConfigurer {

    private final WebSocketHandler webSocketHandler;

    public WebSocketConfig(WebSocketHandler webSocketHandler) {
        this.webSocketHandler = webSocketHandler;
    }

    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(webSocketHandler, "/ws-endpoint")
                .setAllowedOrigins("*")
                .addInterceptors(clientUuidHandshakeInterceptor());
    }

    @Bean
    public HandshakeInterceptor clientUuidHandshakeInterceptor() {
        return new HandshakeInterceptor() {

            @Override
            public boolean beforeHandshake(ServerHttpRequest request, ServerHttpResponse response, org.springframework.web.socket.WebSocketHandler wsHandler, Map<String, Object> attributes) {
                // Extract client UUID from query parameters if available
                String query = request.getURI().getQuery();
                if (query != null && query.contains("clientUuid=")) {
                    String[] params = query.split("&");
                    for (String param : params) {
                        if (param.startsWith("clientUuid=")) {
                            String clientUuid = param.substring("clientUuid=".length());
                            attributes.put("clientUuid", clientUuid);
                            break;
                        }
                    }
                }

                attributes.put("startedAt", new SimpleDateFormat("dd/MM/yyyy HH:mm:ss").format(new Date()));
                return true;
            }

            @Override
            public void afterHandshake(ServerHttpRequest request, ServerHttpResponse response, org.springframework.web.socket.WebSocketHandler wsHandler, Exception exception) {
                // Nothing to do after handshake
            }
        };
    }

    @Bean
    public ServletServerContainerFactoryBean createWebSocketContainer() {
        ServletServerContainerFactoryBean servletServerContainerFactoryBean = new ServletServerContainerFactoryBean();
        servletServerContainerFactoryBean.setMaxTextMessageBufferSize(1024 * 1024); // 1 MB
        servletServerContainerFactoryBean.setMaxBinaryMessageBufferSize(1024 * 1024); // if using binary
        return servletServerContainerFactoryBean;
    }
}