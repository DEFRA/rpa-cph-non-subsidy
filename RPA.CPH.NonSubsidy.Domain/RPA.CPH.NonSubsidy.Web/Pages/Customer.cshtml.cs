using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Web.Helpers;
using RPA.CPH.NonSubsidy.Web.Models;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Pages;

[Authorize(Policy = ApplicationServices.BasicAccessPolicy)]
public sealed class CustomerModel(IUnitOfWork uow, IUser user) : PageModel
{
    // Output only: handler parameters retain the original flat form names and validation.
    public Customer Customer { get; private set; }

    public IActionResult OnGet(int? customerId = null)
    {
        if (customerId != null)
        {
            Customer = uow.CustomerRepository.GetById(customerId);
            if (Customer == null)
                return NotFound();
            ViewData["IsUpdate"] = true;
        }
        else
        {
            Customer = new Customer(new Address(), new Land(), new Case(), new Audit());
            ViewData["IsUpdate"] = false;
        }
        return Page();
    }

    public IActionResult OnPost(Customer customer, Case _case, Address address, Land land,
        List<LandParcel> LandParcels, Audit audit, bool IsUpdate, string submit)
    {
        if (submit == "delete")
        {
            uow.CustomerRepository.Delete(customer.CustomerId);
            uow.Commit();
            return RedirectToPage("/Index");
        }

        if (LandParcels == null)
        {
            LandParcels = [];
        }
        else
        {
            var retained = LandParcels.Select((parcel, position) => new { parcel, position })
                .Where(x => (x.parcel.LandParcelId == 0 && x.parcel.GridReference != null) || x.parcel.LandParcelId > 0).ToList();
            HtmlHelperExtensions.PreserveCollectionIndices(HttpContext, "LandParcels", retained.Select(x => x.position));
            LandParcels = retained.Select(x => x.parcel).ToList();
        }

        customer.Case = _case;
        customer.Addresses = [address];
        customer.Land = [land];
        land.LandParcels = LandParcels;
        customer.Audit = audit;
        Customer = customer;
        ViewData["IsUpdate"] = IsUpdate;

        if (!ModelState.IsValid)
            return Page();

        if (LandParcels.Any(x => x.Active) && LandParcels.Count(x => x.IsPlaceOfBusiness && x.Active) != 1)
        {
            ModelState.AddModelError("POB", LandParcels.Count(x => x.IsPlaceOfBusiness && x.Active) == 0
                ? "One POB is required." : "One POB is allowed.");
            return Page();
        }

        if (LandParcels.Where(x => x.Active).GroupBy(x => x.GridReference).Any(group => group.Count() > 1))
        {
            ModelState.AddModelError("GridReference", "Duplicate Grid Reference identified.");
            return Page();
        }

        customer.Audit.Update(user.Name);
        if (IsUpdate)
        {
            foreach (var landParcel in land.LandParcels)
            {
                if (landParcel.LandParcelId == 0)
                {
                    if (landParcel.Active)
                        uow.LandParcelRepository.Create(landParcel);
                }
                else
                {
                    uow.LandParcelRepository.Update(landParcel);
                }
            }
            uow.CustomerRepository.Update(customer);
            uow.CaseRepository.Update(_case);
            uow.AddressRepository.Update(address);
            uow.LandRepository.Update(land);
            uow.AuditRepository.Update(audit);
        }
        else
        {
            land.LandParcels = LandParcels.Where(x => x.Active).ToList();
            uow.CustomerRepository.Create(customer);
        }
        uow.Commit();
        return RedirectToPage("/Index");
    }
}
