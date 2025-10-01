package com.henrique.person.service.handler;

import org.springframework.web.socket.WebSocketSession;

import java.io.IOException;

public abstract class AbstractServiceHandler<T> {

    private final Class<T> type;

    public AbstractServiceHandler(Class<T> clazz) {
        this.type = clazz;
    }

    public abstract void process(WebSocketSession session, T t) throws IOException;

    public Class<T> getType() {
        return type;
    }
}
