using System.Data;
using Dapper;
using Microsoft.AspNetCore.Mvc.RazorPages;

namespace AcmeStub.Pages;

public sealed class AdminModel : PageModel
{
    private readonly IDbConnection _db;

    public AdminModel(IDbConnection db) => _db = db;

    public sealed record OrderRow(int Id, int CustomerId, decimal Amount, DateTime CreatedAt);
    public sealed record Customer(int Id, string Name);

    public IReadOnlyList<OrderRow> Orders { get; private set; } = Array.Empty<OrderRow>();
    public IReadOnlyList<Customer> Customers { get; private set; } = Array.Empty<Customer>();
    public string PodName => Environment.MachineName;
    public bool DbReachable { get; private set; }

    // Account-specific values surfaced at runtime from env vars injected by
    // the Deployment manifest. Keeps the source repo free of AWS account IDs.
    public string AwsAccountId      => Environment.GetEnvironmentVariable("AWS_ACCOUNT_ID") ?? "AWS_ACCOUNT_ID";
    public string AwsRegion         => Environment.GetEnvironmentVariable("AWS_REGION") ?? "us-east-1";
    public string EksCluster        => Environment.GetEnvironmentVariable("EKS_CLUSTER_NAME") ?? "acme-proof-of-life";
    public string EdgeSqlInstanceId => Environment.GetEnvironmentVariable("EDGE_SQL_INSTANCE_ID") ?? "EDGE_SQL_INSTANCE_ID";

    public async Task OnGetAsync()
    {
        try
        {
            var orders = await _db.QueryAsync<OrderRow>(@"
                SELECT TOP 10 id AS Id, customer_id AS CustomerId,
                       amount AS Amount, created_at AS CreatedAt
                FROM dbo.orders ORDER BY id DESC");
            Orders = orders.ToList();

            var customers = await _db.QueryAsync<Customer>(
                "SELECT id AS Id, name AS Name FROM dbo.customers ORDER BY id");
            Customers = customers.ToList();

            DbReachable = true;
        }
        catch
        {
            DbReachable = false;
        }
    }
}
