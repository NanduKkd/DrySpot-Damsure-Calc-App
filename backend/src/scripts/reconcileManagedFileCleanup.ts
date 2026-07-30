const usage = `Usage: npm run managed-cleanup:reconcile -- [--exhausted] [--retry-exhausted] [--limit=N]

  --exhausted       Inspect exhausted rows only; makes no changes.
  --retry-exhausted Explicitly requeue exhausted rows, then reconcile due rows.
  --limit=N         Process at most N due rows (default 100, maximum 1000).`;

const main = async () => {
  const args = new Set(process.argv.slice(2));
  if (args.has('--help') || args.has('-h')) {
    console.log(usage);
    return;
  }
  const limitArgument = [...args].find((argument) => argument.startsWith('--limit='));
  const parsedLimit = limitArgument ? Number.parseInt(limitArgument.slice('--limit='.length), 10) : 100;
  if (!Number.isInteger(parsedLimit) || parsedLimit < 1 || parsedLimit > 1000) {
    throw new Error('--limit must be an integer from 1 through 1000.');
  }
  const [{ sequelize }, cleanup] = await Promise.all([
    import('../models'),
    import('../services/managedFileCleanup'),
  ]);
  closeDatabase = () => sequelize.close();
  await sequelize.authenticate();
  if (args.has('--exhausted')) {
    console.log(JSON.stringify(await cleanup.listExhaustedManagedFileCleanup(), null, 2));
    return;
  }
  if (args.has('--retry-exhausted')) {
    const [updated] = await cleanup.retryExhaustedManagedFileCleanup();
    console.log(`Requeued ${updated} exhausted managed-file cleanup row(s).`);
  }
  console.log(JSON.stringify(await cleanup.reconcileDueManagedFileCleanup({ limit: parsedLimit })));
};

let closeDatabase: (() => Promise<void>) | undefined;
void main()
  .catch((error) => {
    console.error('Managed-file cleanup reconciliation failed:', error);
    process.exitCode = 1;
  })
  .finally(async () => {
    if (closeDatabase) await closeDatabase();
  });
