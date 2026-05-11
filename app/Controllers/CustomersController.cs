using System.Data;
using Dapper;
using Microsoft.AspNetCore.Mvc;

namespace AcmeStub.Controllers;

[ApiController]
[Route("api/customers")]
public sealed class CustomersController : ControllerBase
{
    private readonly IDbConnection _db;

    public CustomersController(IDbConnection db) => _db = db;

    public sealed record Customer(int Id, string Name, string Email);

    [HttpGet]
    public async Task<IEnumerable<Customer>> Get() =>
        await _db.QueryAsync<Customer>(
            "SELECT TOP 5 id AS Id, name AS Name, email AS Email FROM dbo.customers ORDER BY id");
}
