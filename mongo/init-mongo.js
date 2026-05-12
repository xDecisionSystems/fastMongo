const dbName = process.env.MONGO_DB_NAME;
const writerPassword = process.env.MONGO_WRITER_PASSWORD;
const readerPassword = process.env.MONGO_READER_PASSWORD;

if (!dbName || !writerPassword || !readerPassword) {
  throw new Error("Missing required environment variables");
}

db = db.getSiblingDB(dbName);

db.createUser({
  user: "writer",
  pwd: writerPassword,
  roles: [{ role: "readWrite", db: dbName }]
});

db.createUser({
  user: "reader",
  pwd: readerPassword,
  roles: [{ role: "read", db: dbName }]
});

print(`Initialized DB: ${dbName}`);
