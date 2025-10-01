// Connection status shared across app (framework-agnostic)
let connected = false
const connectionListeners = new Set()

function setConnected(value) {
    if (connected !== value) {
        connected = value
        // notify listeners
        connectionListeners.forEach((cb) => {
            try { cb(connected) } catch (e) { console.error('Error in connection listener', e) }
        })
    }
}

// Create a single WebSocket client instance
let socket = null

// Message queue for storing messages during disconnection
const messageQueue = []

// Subscription callbacks
const subscriptions = new Map()

// Generate or retrieve client UUID
function getClientUuid() {
    let clientUuid = localStorage.getItem('client_uuid')
    if (!clientUuid) {
        clientUuid = generateUuid()
        localStorage.setItem('client_uuid', clientUuid)
    }
    return clientUuid
}

// Generate a UUID v4
function generateUuid() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function (c) {
        const r = Math.random() * 16 | 0
        const v = c === 'x' ? r : (r & 0x3 | 0x8)
        return v.toString(16)
    })
}

// Client UUID
const clientUuid = getClientUuid()

// Reconnection settings
const reconnectSettings = {
    delay: 5000, // Start with a 1 second delay
    maxDelay: 30000, // Max delay of 30 seconds
    backoffMultiplier: 1.5, // Exponential backoff
    maxRetries: 100, // Maximum number of reconnect attempts
    count: 0 // Current reconnect count
}

// Initialize the WebSocket connection
function initWebSocket() {
    if (socket) {
        try {
            socket.close()
        } catch (e) {
            console.error('Error closing WebSocket', e)
        }
    }

    // Create a new WebSocket connection
    const wsUrl = `${window.location.protocol === 'https:' ? 'wss:' : 'ws:'}//${window.location.host}/ws-endpoint?clientUuid=${encodeURIComponent(clientUuid)}`
    socket = new WebSocket(wsUrl)

    // Set up event handlers
    socket.onopen = (event) => {
        console.log('WebSocket connection established', event)
        setConnected(true)

        // Process any queued messages
        if (messageQueue.length > 0) {
            console.log(`Connection restored. Processing ${messageQueue.length} queued messages.`)
            processMessageQueue()
        }

        // Reset reconnect counter on successful connection
        reconnectSettings.count = 0
    }

    socket.onclose = (event) => {
        console.log('WebSocket connection closed', event)
        setConnected(false)

        // Attempt to reconnect if not a clean close
        if (!event.wasClean && reconnectSettings.count < reconnectSettings.maxRetries) {
            const delay = Math.min(reconnectSettings.delay * Math.pow(reconnectSettings.backoffMultiplier, reconnectSettings.count), reconnectSettings.maxDelay)

            console.log(`Attempting to reconnect (${reconnectSettings.count + 1}) in ${delay}ms...`)
            reconnectSettings.count++

            setTimeout(initWebSocket, delay)
        }
    }

    socket.onerror = (event) => {
        console.error('WebSocket error', event)
    }

    socket.onmessage = (event) => {
        try {
            const message = JSON.parse(event.data)
            const {destination, body} = message

            // Find and call all callbacks for this destination
            if (subscriptions.has(destination)) {
                const callbacks = subscriptions.get(destination)
                callbacks.forEach(callback => {
                    try {
                        callback({body: body})
                    } catch (err) {
                        console.error(`Error in subscription callback for ${destination}`, err)
                    }
                })
            }
        } catch (err) {
            console.error('Error processing incoming message', err)
        }
    }
}

// Subscribe to a topic
function subscribe(destination, callback) {

    // Automatically append client UUID to user queue destinations
    let actualDestination = destination

    // Add callback to the subscription map
    if (!subscriptions.has(actualDestination)) {
        subscriptions.set(actualDestination, [])
    }

    const callbacks = subscriptions.get(actualDestination)
    callbacks.push(callback)

    // Return an object with an unsubscribe method to mimic STOMP API
    return {
        id: generateUuid(),
        unsubscribe: () => {
            const index = callbacks.indexOf(callback)
            if (index !== -1) {
                callbacks.splice(index, 1)
            }
            if (callbacks.length === 0) {
                subscriptions.delete(actualDestination)
            }
        }
    }
}

// Process queued messages
function processMessageQueue() {
    if (messageQueue.length > 0 && socket && socket.readyState === WebSocket.OPEN) {
        console.log(`Processing message queue (${messageQueue.length} messages)`)

        // Create a copy of the queue and clear the original
        const queueCopy = [...messageQueue]
        messageQueue.length = 0

        // Process each message
        queueCopy.forEach(message => {
            try {
                // No need to modify destination here as it was already modified when added to the queue
                socket.send(JSON.stringify(message))
                console.log('Queued message sent successfully', message.destination)
            } catch (err) {
                console.error('Error sending queued message', err)
                // If sending fails, add back to queue
                messageQueue.push(message)
            }
        })
    }
}

// Publish a message
function publish(destination, body = null) {
    // Automatically append client UUID to user queue destinations

    const message = {
        destination
    }

    if (body) {
        message.body = typeof body === 'string' ? body : JSON.stringify(body)
    }

    // If not connected, queue the message
    if (!socket || socket.readyState !== WebSocket.OPEN) {
        console.warn('Cannot publish: WebSocket is not connected, message queued')
        messageQueue.push(message)
        return false
    }

    try {
        socket.send(JSON.stringify(message))
        return true
    } catch (err) {
        console.error('Error publishing message', err)
        // Queue the message if sending fails
        messageQueue.push(message)
        return false
    }
}

// Clean up resources
function disconnect() {
    if (socket) {
        try {
            socket.close()
        } catch (err) {
            console.error('Error closing WebSocket', err)
        }
        socket = null
    }

    // Clear subscriptions
    subscriptions.clear()
}

// Get the client instance (for advanced usage)
function getClient() {
    return socket
}

// Helpers for connection status
function getConnected() {
    return connected
}
function onConnectionChange(callback) {
    connectionListeners.add(callback)
    // Immediately inform current state
    try { callback(connected) } catch (e) { console.error('Error in connection listener (initial)', e) }
    return () => connectionListeners.delete(callback)
}

// Export the WebSocket service
export default {
    initWebSocket,
    subscribe,
    publish,
    disconnect,
    getClient,
    processMessageQueue,
    getConnected,
    onConnectionChange,
    // Getter for message queue status
    get queueSize() {
        return messageQueue.length
    },
    // Expose client UUID
    get clientUuid() {
        return clientUuid
    }
}