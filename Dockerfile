# Install dependencies and build the app
FROM node:20-alpine AS builder

WORKDIR /app

# add yarn.lock as you wish, I don't COPY yarn.lock to minimize the image
COPY package.json ./
RUN yarn install

COPY . .
RUN yarn build

# Install Install production dependencies
FROM node:20-alpine AS production-dependencies
WORKDIR /app

# add yarn.lock as you wish, I don't COPY yarn.lock to minimize the image
COPY package.json ./
RUN yarn install

# Prepare the final image
FROM node:20-alpine
WORKDIR /app

COPY --from=builder /app/.next ./.next
# If your nextjs project doesn't have public directory, then delete below command! Or, create the public directory
COPY --from=builder /app/public ./public
COPY --from=production-dependencies /app/node_modules ./node_modules
COPY package.json ./

RUN chown -R node:node /app
USER node

EXPOSE 3001

CMD ["yarn", "start"]
