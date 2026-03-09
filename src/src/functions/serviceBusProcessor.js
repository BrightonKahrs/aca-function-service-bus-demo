const { app } = require('@azure/functions');

app.serviceBusQueue('serviceBusProcessor', {
    connection: 'ServiceBusConnection',
    queueName: 'demo-queue',
    handler: async (message, context) => {
        context.log(`Service Bus queue trigger processed message:`);
        context.log(`  Message ID: ${context.triggerMetadata.messageId}`);
        context.log(`  Enqueued Time: ${context.triggerMetadata.enqueuedTimeUtc}`);
        context.log(`  Delivery Count: ${context.triggerMetadata.deliveryCount}`);

        if (typeof message === 'object') {
            context.log(`  Body (JSON): ${JSON.stringify(message, null, 2)}`);
        } else {
            context.log(`  Body: ${message}`);
        }

        // Simulate processing work
        await new Promise(resolve => setTimeout(resolve, 2000));
        context.log(`  Processing complete.`);
    }
});
