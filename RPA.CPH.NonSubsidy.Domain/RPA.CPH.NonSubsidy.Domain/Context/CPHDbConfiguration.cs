using System.Data.Entity;
using System.Data.Entity.Infrastructure;
using System.Data.Entity.SqlServer;

namespace RPA.CPH.NonSubsidy.Domain.Context
{
    // Code-based replacement for the <entityFramework> section of App.config / Web.config.
    public class CPHDbConfiguration : DbConfiguration
    {
        public CPHDbConfiguration()
        {
            SetProviderServices("System.Data.SqlClient", SqlProviderServices.Instance);
            SetDefaultConnectionFactory(new SqlConnectionFactory());
        }
    }
}
