import app from './app';

const host = process.env.HOST || '0.0.0.0';
const port = process.env.PORT || 3000;

app.listen(Number(port), host, () => {
  console.log(`Server running on http://${host}:${port}`);
});
