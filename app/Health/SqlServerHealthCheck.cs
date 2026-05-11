using System.Data;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace AcmeStub.Health;

public sealed class SqlServerHealthCheck : IHealthCheck
{
    private readonly IDbConnection _db;

    public SqlServerHealthCheck(IDbConnection db) => _db = db;

    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            if (_db.State != ConnectionState.Open) _db.Open();
            using var cmd = _db.CreateCommand();
            cmd.CommandText = "SELECT 1";
            cmd.CommandTimeout = 2;
            await Task.Run(() => cmd.ExecuteScalar(), cancellationToken);
            return HealthCheckResult.Healthy();
        }
        catch (Exception ex)
        {
            return HealthCheckResult.Degraded("SQL unreachable", ex);
        }
    }
}
