using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Repository;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace RPA.CPH.NonSubsidy.Domain.Interfaces
{
    public interface IUnitOfWork : IDisposable
    {
        IRepository<Customer> CustomerRepository { get; }

        IRepository<Address> AddressRepository { get; }

        IRepository<Land> LandRepository { get; }

        IRepository<Case> CaseRepository { get; }

        IRepository<LandParcel> LandParcelRepository { get; }

        IRepository<Audit> AuditRepository { get; }
                
        void Commit();
    }
}
