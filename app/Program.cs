using System.Data;
using AcmeStub.Health;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorPages();
builder.Services.AddControllers();

builder.Services.AddScoped<IDbConnection>(_ =>
{
    var cs = builder.Configuration.GetConnectionString("Default")
             ?? throw new InvalidOperationException(
                 "ConnectionStrings__Default is required (mounted from k8s Secret 'acme-db-creds').");
    return new SqlConnection(cs);
});

builder.Services
    .AddHealthChecks()
    .AddCheck<SqlServerHealthCheck>("sqlserver");

var app = builder.Build();

app.UseStaticFiles();
app.MapHealthChecks("/health");
app.MapControllers();
app.MapRazorPages();
app.MapGet("/", () => Results.Redirect("/admin"));

app.Run();
